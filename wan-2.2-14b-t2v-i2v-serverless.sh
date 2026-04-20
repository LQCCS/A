#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
INPUTS_DIR="${COMFYUI_DIR}/input"
WORKFLOWS_DIR="${COMFYUI_DIR}/user/default/workflows"
HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3
WGET_MAX_PARALLEL=5
MODEL_LOG="${MODEL_LOG:-/var/log/portal/comfyui.log}"

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors
  |$MODELS_DIR/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors
  |$MODELS_DIR/vae/wan_2.1_vae.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors
  |$MODELS_DIR/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors
  |$MODELS_DIR/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
)

# Wget declarations: "URL|OUTPUT_PATH"
WGET_DOWNLOADS=(
)

### End Configuration ###

mkdir -p "$(dirname "$MODEL_LOG")"

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$MODEL_LOG"
}

script_cleanup() {
    log "Cleaning up semaphore directory..."
    rm -rf "$HF_SEMAPHORE_DIR"
    find "$MODELS_DIR" -name "*.lock" -type f -mmin +60 -delete 2>/dev/null || true
    find "$INPUTS_DIR" -name "*.lock" -type f -mmin +60 -delete 2>/dev/null || true
}

script_error() {
    local exit_code=$?
    local line_number=$1
    log "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

download_hf_file() {
    local url="$1"
    local output_path="$2"
    local lockfile="${output_path}.lock"
    local max_retries=5
    local retry_delay=2

    local slot
    slot=$(acquire_slot "$HF_SEMAPHORE_DIR/hf" "$HF_MAX_PARALLEL")
    mkdir -p "$(dirname "$output_path")"

    (
        if ! flock -x -w 300 200; then
            log "[ERROR] Could not acquire lock for $output_path after 300s"
            release_slot "$slot"
            exit 1
        fi

        if [ -f "$output_path" ]; then
            log "File already exists: $output_path (skipping)"
            release_slot "$slot"
            exit 0
        fi

        local repo file_path
        repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
        file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')

        if [ -z "$repo" ] || [ -z "$file_path" ]; then
            log "[ERROR] Invalid HuggingFace URL: $url"
            release_slot "$slot"
            exit 1
        fi

        local temp_dir
        temp_dir=$(mktemp -d)
        local attempt=1
        local current_delay=$retry_delay

        while [ $attempt -le $max_retries ]; do
            log "Downloading $repo/$file_path (attempt $attempt/$max_retries)..."

            if hf download "$repo" \
                "$file_path" \
                --local-dir "$temp_dir" \
                --cache-dir "$temp_dir/.cache" 2>&1 | tee -a "$MODEL_LOG"; then

                if [ -f "$temp_dir/$file_path" ]; then
                    mv "$temp_dir/$file_path" "$output_path"
                    rm -rf "$temp_dir"
                    release_slot "$slot"
                    log "✓ Successfully downloaded: $output_path"
                    exit 0
                else
                    log "✗ Download command succeeded but file not found at $temp_dir/$file_path"
                fi
            fi

            log "✗ Download failed (attempt $attempt/$max_retries), retrying in ${current_delay}s..."
            sleep $current_delay
            current_delay=$((current_delay * 2))
            attempt=$((attempt + 1))
        done

        log "[ERROR] Failed to download $output_path after $max_retries attempts"
        rm -rf "$temp_dir"
        release_slot "$slot"
        exit 1
    ) 200>"$lockfile"

    local result=$?
    rm -f "$lockfile"
    return $result
}

download_wget_file() {
    local url="$1"
    local output_path="$2"
    local lockfile="${output_path}.lock"
    local max_retries=5
    local retry_delay=2

    local slot
    slot=$(acquire_slot "$HF_SEMAPHORE_DIR/wget" "$WGET_MAX_PARALLEL")
    mkdir -p "$(dirname "$output_path")"

    (
        if ! flock -x -w 300 200; then
            log "[ERROR] Could not acquire lock for $output_path after 300s"
            release_slot "$slot"
            exit 1
        fi

        if [ -f "$output_path" ]; then
            log "File already exists: $output_path (skipping)"
            release_slot "$slot"
            exit 0
        fi

        local temp_file
        temp_file=$(mktemp)
        local attempt=1
        local current_delay=$retry_delay

        while [ $attempt -le $max_retries ]; do
            log "Downloading $url (attempt $attempt/$max_retries)..."

            if wget \
                --quiet \
                --show-progress \
                --timeout=60 \
                --tries=1 \
                --output-document="$temp_file" \
                "$url" 2>&1 | tee -a "$MODEL_LOG"; then

                if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
                    mv "$temp_file" "$output_path"
                    release_slot "$slot"
                    log "✓ Successfully downloaded: $output_path"
                    exit 0
                else
                    log "✗ Download command succeeded but file is empty or missing"
                fi
            fi

            log "✗ Download failed (attempt $attempt/$max_retries), retrying in ${current_delay}s..."
            sleep $current_delay
            current_delay=$((current_delay * 2))
            attempt=$((attempt + 1))
        done

        log "[ERROR] Failed to download $output_path after $max_retries attempts"
        rm -f "$temp_file"
        release_slot "$slot"
        exit 1
    ) 200>"$lockfile"

    local result=$?
    rm -f "$lockfile"
    return $result
}

acquire_slot() {
    local prefix="$1"
    local max_slots="$2"

    while true; do
        local count
        count=$(find "$(dirname "$prefix")" -name "$(basename "$prefix")_*" 2>/dev/null | wc -l)
        if [ "$count" -lt "$max_slots" ]; then
            local slot="${prefix}_$$_$RANDOM"
            touch "$slot"
            echo "$slot"
            return 0
        fi
        sleep 0.5
    done
}

release_slot() {
    rm -f "$1"
}

write_api_workflow() {
    local workflow_json
    read -r -d '' workflow_json << 'WORKFLOW_JSON' || true
{
    "90": {
        "inputs": {
        "clip_name": "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
        "type": "wan",
        "device": "default"
        },
        "class_type": "CLIPLoader",
        "_meta": {
        "title": "Load CLIP"
        }
    },
    "91": {
        "inputs": {
        "text": "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走，裸露，NSFW",
        "clip": [
            "90",
            0
        ]
        },
        "class_type": "CLIPTextEncode",
        "_meta": {
        "title": "CLIP Text Encode (Negative Prompt)"
        }
    },
    "92": {
        "inputs": {
        "vae_name": "wan_2.1_vae.safetensors"
        },
        "class_type": "VAELoader",
        "_meta": {
        "title": "Load VAE"
        }
    },
    "93": {
        "inputs": {
        "shift": 8.000000000000002,
        "model": [
            "101",
            0
        ]
        },
        "class_type": "ModelSamplingSD3",
        "_meta": {
        "title": "ModelSamplingSD3"
        }
    },
    "94": {
        "inputs": {
        "shift": 8,
        "model": [
            "102",
            0
        ]
        },
        "class_type": "ModelSamplingSD3",
        "_meta": {
        "title": "ModelSamplingSD3"
        }
    },
    "95": {
        "inputs": {
        "add_noise": "disable",
        "noise_seed": 0,
        "steps": 20,
        "cfg": 3.5,
        "sampler_name": "euler",
        "scheduler": "simple",
        "start_at_step": 10,
        "end_at_step": 10000,
        "return_with_leftover_noise": "disable",
        "model": [
            "94",
            0
        ],
        "positive": [
            "99",
            0
        ],
        "negative": [
            "91",
            0
        ],
        "latent_image": [
            "96",
            0
        ]
        },
        "class_type": "KSamplerAdvanced",
        "_meta": {
        "title": "KSampler (Advanced)"
        }
    },
    "96": {
        "inputs": {
        "add_noise": "enable",
        "noise_seed": "__RANDOM_INT__",
        "steps": 20,
        "cfg": 3.5,
        "sampler_name": "euler",
        "scheduler": "simple",
        "start_at_step": 0,
        "end_at_step": 10,
        "return_with_leftover_noise": "enable",
        "model": [
            "93",
            0
        ],
        "positive": [
            "99",
            0
        ],
        "negative": [
            "91",
            0
        ],
        "latent_image": [
            "104",
            0
        ]
        },
        "class_type": "KSamplerAdvanced",
        "_meta": {
        "title": "KSampler (Advanced)"
        }
    },
    "97": {
        "inputs": {
        "samples": [
            "95",
            0
        ],
        "vae": [
            "92",
            0
        ]
        },
        "class_type": "VAEDecode",
        "_meta": {
        "title": "VAE Decode"
        }
    },
    "98": {
        "inputs": {
        "filename_prefix": "video/ComfyUI",
        "format": "auto",
        "codec": "auto",
        "video": [
            "100",
            0
        ]
        },
        "class_type": "SaveVideo",
        "_meta": {
        "title": "Save Video"
        }
    },
    "99": {
        "inputs": {
        "text": "Beautiful young European woman with honey blonde hair gracefully turning her head back over shoulder, gentle smile, bright eyes looking at camera. Hair flowing in slow motion as she turns. Soft natural lighting, clean background, cinematic portrait.",
        "clip": [
            "90",
            0
        ]
        },
        "class_type": "CLIPTextEncode",
        "_meta": {
        "title": "CLIP Text Encode (Positive Prompt)"
        }
    },
    "100": {
        "inputs": {
        "fps": 16,
        "images": [
            "97",
            0
        ]
        },
        "class_type": "CreateVideo",
        "_meta": {
        "title": "Create Video"
        }
    },
    "101": {
        "inputs": {
        "unet_name": "wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors",
        "weight_dtype": "default"
        },
        "class_type": "UNETLoader",
        "_meta": {
        "title": "Load Diffusion Model"
        }
    },
    "102": {
        "inputs": {
        "unet_name": "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors",
        "weight_dtype": "default"
        },
        "class_type": "UNETLoader",
        "_meta": {
        "title": "Load Diffusion Model"
        }
    },
    "104": {
        "inputs": {
        "width": 640,
        "height": 640,
        "length": 81,
        "batch_size": 1
        },
        "class_type": "EmptyHunyuanLatentVideo",
        "_meta": {
        "title": "EmptyHunyuanLatentVideo"
        }
    }
}
WORKFLOW_JSON

    rm -f /opt/comfyui-api-wrapper/payloads/*
    cat > /opt/comfyui-api-wrapper/payloads/wan_2.2_i2v.json << EOF
{
    "input": {
        "request_id": "",
        "workflow_json": ${workflow_json}
    }
}
EOF

    local benchmark_dir="$WORKSPACE/vast-pyworker/workers/comfyui-json/misc"
    while [[ ! -d "$benchmark_dir" ]]; do
        sleep 1
    done

    echo "$workflow_json" > "$benchmark_dir/benchmark.json"
}

set_cleanup_job() {
    local script_dir="/opt/instance-tools/bin"
    local script_path="${script_dir}/clean-output.sh"

    mkdir -p "$script_dir"

    if [[ ! -f "$script_path" ]]; then
        cat > "$script_path" << 'CLEAN_OUTPUT'
#!/bin/bash

output_dir="${WORKSPACE:-/workspace}/ComfyUI/output/"
min_free_mb=512
available_space=$(df -m "${output_dir}" | awk 'NR==2 {print $4}')
if [[ "$available_space" -lt "$min_free_mb" ]]; then
    oldest=$(find "${output_dir}" -mindepth 1 -type f -printf "%T@\n" 2>/dev/null | sort -n | head -1 | awk '{printf "%.0f", $1}')
    if [[ -n "$oldest" ]]; then
        cutoff=$(awk "BEGIN {printf \"%.0f\", ${oldest}+86400}")
        find "${output_dir}" -mindepth 1 -type f ! -newermt "@${cutoff}" -delete
        find "${output_dir}" -mindepth 1 -xtype l -delete
        find "${output_dir}" -mindepth 1 -type d -empty -delete
    fi
fi
CLEAN_OUTPUT
        chmod +x "$script_path"
    fi

    local cron_exists=0
    if crontab -l 2>/dev/null | grep -qF 'clean-output.sh'; then
        cron_exists=1
    fi

    if [[ "$cron_exists" -eq 0 ]]; then
        (crontab -l 2>/dev/null || true; echo "*/10 * * * * ${script_path}") | crontab -
    fi
}

main() {
    log "Starting ComfyUI provisioning..."

    if [ -f /venv/main/bin/activate ]; then
        # shellcheck source=/dev/null
        . /venv/main/bin/activate
    fi

    rm -rf "$HF_SEMAPHORE_DIR"
    mkdir -p "$HF_SEMAPHORE_DIR"
    mkdir -p "$WORKFLOWS_DIR"
    mkdir -p "$INPUTS_DIR"
    mkdir -p "$MODELS_DIR"/{checkpoints,text_encoders,latent_upscale_models,loras,vae,diffusion_models}

    write_api_workflow
    set_cleanup_job

    local pids=()

    for model in "${HF_MODELS[@]}"; do
        url="${model%%|*}"
        output_path="${model##*|}"
        url=$(echo "$url" | xargs)
        output_path=$(echo "$output_path" | xargs)

        log "Queuing HF download: $url -> $output_path"
        download_hf_file "$url" "$output_path" &
        pids+=($!)
    done

    for item in "${WGET_DOWNLOADS[@]}"; do
        [[ -z "${item// }" ]] && continue
        url="${item%%|*}"
        output_path="${item##*|}"
        url=$(echo "$url" | xargs)
        output_path=$(echo "$output_path" | xargs)

        log "Queuing wget download: $url -> $output_path"
        download_wget_file "$url" "$output_path" &
        pids+=($!)
    done

    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            log "[ERROR] Download process $pid failed"
            failed=1
        fi
    done

    if [ $failed -eq 1 ]; then
        log "[ERROR] One or more downloads failed"
        exit 1
    fi

    log "✓ All downloads completed successfully"
}

main