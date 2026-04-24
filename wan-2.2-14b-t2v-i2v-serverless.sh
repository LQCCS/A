#!/bin/bash

# 注意：故意不使用 set -e（errexit），避免任何单点失败中断整个 provisioning 流程。
# 模型下载、补丁等每个函数自行处理错误，主流程始终跑完。
set -uo pipefail

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

# HuggingFace Token（用于 gated repo 下载如 FLUX.1-dev，同时解除匿名限速）
export HF_TOKEN="${HF_TOKEN:-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}"
export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors
  |$MODELS_DIR/text_encoders/umt5_xxl_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors
  |$MODELS_DIR/vae/wan_2.1_vae.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors
  |$MODELS_DIR/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors
  |$MODELS_DIR/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  # FLUX.1 dev bf16 全精度（~24GB，Gated Repo，需在 HF 接受协议后才能下载；403 时自动跳过不阻塞）
  "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors
  |$MODELS_DIR/diffusion_models/flux1-dev.safetensors"
  # FLUX.1 dev fp8 fallback（~12GB，无需 HF 协议，bf16 下载失败时备用）
  "https://huggingface.co/Kijai/flux-fp8/resolve/main/flux1-dev-fp8-e4m3fn.safetensors
  |$MODELS_DIR/diffusion_models/flux1-dev-fp8.safetensors"
  # FLUX.1 Kontext dev fp8 (reference-based editing / multi-ref style transfer)
  "https://huggingface.co/Kijai/flux-fp8/resolve/main/flux1-kontext-dev-fp8-e4m3fn.safetensors
  |$MODELS_DIR/diffusion_models/flux1-kontext-dev-fp8.safetensors"
  # XLabs Realism LoRA for FLUX（压制卡通/动漫风，增强写实摄影质感，适合美妆/产品场景）
  "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors
  |$MODELS_DIR/loras/flux-realism-lora.safetensors"
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors
  |$MODELS_DIR/text_encoders/clip_l.safetensors"
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors
  |$MODELS_DIR/text_encoders/t5xxl_fp8_e4m3fn.safetensors"
  # ae.safetensors (FLUX.1 VAE) — Gated Repo，403 时自动跳过不阻塞，T2I 需要时请先在 HF 接受协议
  "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors
  |$MODELS_DIR/vae/ae.safetensors"
  # Wan 2.2 Animate 14B (video-to-video / image-to-video animation, bf16 only)
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_animate_14B_bf16.safetensors"
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

trap script_cleanup EXIT

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

            local dl_output
            local hf_token_arg=""
            if [ -n "${HF_TOKEN:-}" ]; then
                hf_token_arg="--token $HF_TOKEN"
            fi
            dl_output=$(hf download "$repo" \
                "$file_path" \
                --local-dir "$temp_dir" \
                --cache-dir "$temp_dir/.cache" \
                $hf_token_arg 2>&1 | tee -a "$MODEL_LOG")
            local dl_exit=${PIPESTATUS[0]}

            # 403 GatedRepoError — 永久性权限错误，立即跳过不重试
            if echo "$dl_output" | grep -q "GatedRepoError\|403 Client Error\|Access to model.*is restricted"; then
                log "⚠️  Skipping $output_path — Gated Repo (403), set HF_TOKEN env var and accept terms on HuggingFace to enable download"
                rm -rf "$temp_dir"
                release_slot "$slot"
                exit 0
            fi

            if [ $dl_exit -eq 0 ] && [ -f "$temp_dir/$file_path" ]; then
                mv "$temp_dir/$file_path" "$output_path"
                rm -rf "$temp_dir"
                release_slot "$slot"
                log "✓ Successfully downloaded: $output_path"
                exit 0
            else
                log "✗ Download command succeeded but file not found at $temp_dir/$file_path"
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
        "clip_name": "umt5_xxl_fp16.safetensors",
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
        "unet_name": "wan2.2_t2v_high_noise_14B_fp16.safetensors",
        "weight_dtype": "default"
        },
        "class_type": "UNETLoader",
        "_meta": {
        "title": "Load Diffusion Model"
        }
    },
    "102": {
        "inputs": {
        "unet_name": "wan2.2_t2v_low_noise_14B_fp16.safetensors",
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

    # benchmark 只需 wan_2.1_vae.safetensors（~388MB），写轻量 VAE-only workflow，
    # 避免需要 14B 大模型 → 下载超时 → 实例 Error 销毁的死循环。
    local benchmark_workflow_json
    read -r -d '' benchmark_workflow_json << 'BENCH_EOF' || true
{
  "1": {"inputs": {"width": 64, "height": 64, "batch_size": 1}, "class_type": "EmptyLatentImage", "_meta": {"title": "Empty Latent"}},
  "2": {"inputs": {"vae_name": "wan_2.1_vae.safetensors"}, "class_type": "VAELoader", "_meta": {"title": "Load VAE"}},
  "3": {"inputs": {"samples": ["1", 0], "vae": ["2", 0]}, "class_type": "VAEDecode", "_meta": {"title": "VAE Decode"}},
  "4": {"inputs": {"images": ["3", 0], "filename_prefix": "benchmark"}, "class_type": "SaveImage", "_meta": {"title": "Save Image"}}
}
BENCH_EOF

    local benchmark_dir="$WORKSPACE/vast-pyworker/workers/comfyui-json/misc"
    while [[ ! -d "$benchmark_dir" ]]; do
        sleep 1
    done

    echo "$benchmark_workflow_json" > "$benchmark_dir/benchmark.json"
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

patch_ws_timeout() {
    # 等待 comfyui-api-wrapper 安装完毕后，将 WebSocket 空消息超时从 60s 改为 600s，
    # 防止冷启动（模型加载）期间 GPU 满载导致 WebSocket 60s 无消息而误杀任务。
    local target="/opt/comfyui-api-wrapper/workers/generation_worker.py"
    local max_wait=300
    local waited=0

    while [[ ! -f "$target" ]]; do
        if [[ $waited -ge $max_wait ]]; then
            log "[WARN] patch_ws_timeout: $target 未在 ${max_wait}s 内出现，跳过补丁"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if grep -q 'message_timeout = 60\.0' "$target"; then
        sed -i 's/message_timeout = 60\.0/message_timeout = 600.0/' "$target"
        log "✓ patch_ws_timeout: WebSocket message_timeout 已改为 600s"
        # 重启 api-wrapper 使改动生效（uvicorn 以 daemon 模式运行）
        pkill -f 'uvicorn.*main:app' 2>/dev/null || true
        log "✓ patch_ws_timeout: api-wrapper 已重启"
    else
        log "patch_ws_timeout: 未匹配到 60.0（可能已修改或版本不同），跳过"
    fi
}

patch_api_wrapper() {
    # 在 api-wrapper main.py 中实现真正的非阻塞 /generate/async：
    # 立即返回 task_id，后台通过 localhost:18288 调用 /generate 完成推理。
    # 绕过 vast.ai SSL 代理层的 60s 连接超时（499 DISCONNECTED 根因）。
    local target="/opt/comfyui-api-wrapper/main.py"
    local max_wait=300
    local waited=0

    while [[ ! -f "$target" ]]; do
        if [[ $waited -ge $max_wait ]]; then
            log "[WARN] patch_api_wrapper: $target 未在 ${max_wait}s 内出现，跳过"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    # V2 sentinel：心跳流版，防止代理 60s idle-timeout 断连导致 pyworker 误报 idle
    if grep -q 'PATCHED_WORKER_HEARTBEAT_V2' "$target"; then
        log "patch_api_wrapper: 补丁已是最新 V2（心跳流），跳过"
        return 0
    fi
    if grep -q 'PATCHED_WORKER_BUSY_BLOCKING_V1' "$target"; then
        log "patch_api_wrapper: 发现 V1 阻塞补丁，升级到 V2（心跳流）"
    fi

    python3 - << 'PYEOF'
import sys
path = "/opt/comfyui-api-wrapper/main.py"
with open(path) as f:
    content = f.read()

# 移除旧的简单别名（如果存在）
old_alias = '@app.post("/generate/async", response_model=Result)\n'
if old_alias in content:
    content = content.replace(old_alias, '', 1)

# 查找注入标记（原始 /generate 路由）
marker = None
for _q in ("'", '"'):
    _candidate = f"@app.post({_q}/generate{_q},"
    if _candidate in content:
        marker = _candidate
        break
if marker is None:
    print(f"ERROR: marker not found in {path}", file=sys.stderr)
    sys.exit(1)

# 移除旧 V1 注入块（如果存在），避免重复
V1_START = '# ── /generate/async 阻塞版'
if V1_START in content:
    idx_end = content.find(marker)
    if idx_end > 0:
        idx_start = content.rfind(V1_START, 0, idx_end)
        if idx_start >= 0:
            content = content[:idx_start] + content[idx_end:]
            print("✓ V1 injection removed (upgrading to V2)")

injection = '''
# ── /generate/async 心跳流版：防止代理 60s idle-timeout 误断，保持 pyworker busy ──
# PATCHED_WORKER_HEARTBEAT_V2
#
# 根本原因：/generate/async 阻塞执行期间 5-10 分钟无数据传输，
#   vast.ai SSL 代理 60s idle-timeout 主动断连 → pyworker 收到连接中断
#   → num_requests_working = 0 → vast.ai 认为 worker 空闲 → 关闭实例。
#
# 修复方案：
#   1. 生成在独立 asyncio.Task (_bg_run) 中运行，与 HTTP handler 生命周期解耦。
#      即使代理断连 / asyncio cancel，生成任务不受影响，继续跑到完成。
#   2. HTTP handler 返回 StreamingResponse，每 30s yield 一个 \\n 心跳字节，
#      持续向代理发送数据，防止 60s 无数据触发 idle-timeout 断连。
#      pyworker 持续等待响应结束 → num_requests_working > 0 全程保持。
#   3. 生成完毕后，流发送最终 JSON 并关闭。pyworker 收到完整响应后
#      num_requests_working → 0，vast.ai 开始正常 idle 计时。
import json as _json_p
import time as _time_p
import asyncio as _asyncio_p
_async_task_store: dict = {}
_worker_busy: bool = False


@app.post("/generate/async")
async def _generate_async_patched(request: Request):
    global _worker_busy
    from fastapi.responses import JSONResponse as _JR, StreamingResponse as _SR
    if _worker_busy:
        return _JR({"status": "busy", "message": "worker is processing another task"}, status_code=503)
    body = await request.body()
    try:
        _d = _json_p.loads(body)
        _rid = (
            ((_d.get("payload") or {}).get("input") or {}).get("request_id")
            or f"async_{int(_time_p.time() * 1000)}"
        )
    except Exception:
        _rid = f"async_{int(_time_p.time() * 1000)}"
    _async_task_store[_rid] = {"status": "pending"}
    _worker_busy = True
    _done_evt = _asyncio_p.Event()

    async def _bg_run():
        global _worker_busy
        try:
            import aiohttp as _ah
            async with _ah.ClientSession(timeout=_ah.ClientTimeout(total=None)) as _s:
                async with _s.post(
                    "http://127.0.0.1:18288/generate/sync",
                    data=body,
                    headers={"Content-Type": "application/json"},
                ) as _r:
                    _async_task_store[_rid] = await _r.json()
        except Exception as _e:
            _async_task_store[_rid] = {"status": "failed", "message": str(_e)}
        finally:
            _worker_busy = False
            _done_evt.set()

    _asyncio_p.ensure_future(_bg_run())  # 独立任务，不受 handler cancel 影响

    async def _heartbeat():
        # 每 30s 发 \\n 心跳，防止代理 60s 无数据断连；完成后发最终 JSON
        try:
            while not _done_evt.is_set():
                yield b"\\n"
                try:
                    await _asyncio_p.wait_for(
                        _asyncio_p.shield(_done_evt.wait()), timeout=30.0
                    )
                    break
                except _asyncio_p.TimeoutError:
                    continue
            yield _json_p.dumps({"id": _rid, "status": "pending"}).encode()
        except _asyncio_p.CancelledError:
            pass  # 代理关闭连接；_bg_run 不受影响，继续运行到完成

    return _SR(_heartbeat(), media_type="application/json")


@app.get("/result/{_result_rid}")
async def _get_async_result(_result_rid: str):
    _r = _async_task_store.get(_result_rid)
    if _r is None:
        from fastapi.responses import JSONResponse as _JR
        return _JR({"status": "not_found"}, status_code=404)
    return _r


# ─────────────────────────────────────────────────────────────────────────────
'''

content = content.replace(marker, injection + marker, 1)

# ── 修复 watch_disconnect 误取消任务 ──────────────────────────────────────────
old_cancel = '499 DISCONNECTED for {request_id}'
new_cancel = 'client disconnected (task continues) for {request_id}'
if old_cancel in content:
    content = content.replace(old_cancel, new_cancel, 1)
    old_mark = '\n                        await _mark_request_cancelled(request_id)'
    if old_mark in content:
        content = content.replace(old_mark, '\n                        pass  # PATCHED_WORKER_HEARTBEAT_V2', 1)
    else:
        content += '\n# PATCHED_WORKER_HEARTBEAT_V2\n'
    print("✓ watch_disconnect 取消逻辑已禁用")
else:
    content += '\n# PATCHED_WORKER_HEARTBEAT_V2\n'

with open(path, "w") as f:
    f.write(content)
print(f"✓ /generate/async 心跳流 V2 已注入 {path}")
PYEOF

    local py_exit=$?
    if [[ $py_exit -eq 0 ]]; then
        log "✓ patch_api_wrapper: main.py 已打补丁（真正异步）"
        supervisorctl restart api-wrapper 2>/dev/null || pkill -f 'uvicorn.*main:app' 2>/dev/null || true
        log "✓ patch_api_wrapper: api-wrapper 已重启"
    else
        log "[WARN] patch_api_wrapper: Python 补丁失败 (exit $py_exit)"
    fi
}

patch_pyworker() {
    # 在 pyworker worker.py 中注册 /generate/async 和 /generate handler，
    # 并添加 GET /result/{id} 透传到 api-wrapper（port 18288），
    # 使 ttv.py 的异步任务轮询能正确返回结果。
    local target="/workspace/vast-pyworker/workers/comfyui-json/worker.py"
    local max_wait=300
    local waited=0

    while [[ ! -f "$target" ]]; do
        if [[ $waited -ge $max_wait ]]; then
            log "[WARN] patch_pyworker: $target 未在 ${max_wait}s 内出现，跳过"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if grep -q '"/generate/async"' "$target"; then
        log "patch_pyworker: /generate/async 已存在，跳过"
        return 0
    fi

    python3 - << 'PYEOF'
import sys
path = "/workspace/vast-pyworker/workers/comfyui-json/worker.py"
with open(path) as f:
    content = f.read()

# 1. 扩展 handlers 列表，加入 /generate/async 和 /generate
old_handlers = '''    handlers=[
        HandlerConfig(
            route="/generate/sync",
            allow_parallel_requests=False,
            max_queue_time=10.0,
            benchmark_config=BenchmarkConfig(
                dataset=benchmark_dataset,
            )
        )
    ],'''
new_handlers = '''    handlers=[
        HandlerConfig(
            route="/generate/sync",
            allow_parallel_requests=False,
            max_queue_time=10.0,
            benchmark_config=BenchmarkConfig(
                dataset=benchmark_dataset,
            )
        ),
        HandlerConfig(
            route="/generate/async",
            allow_parallel_requests=False,
            max_queue_time=30.0,
        ),
        HandlerConfig(
            route="/generate",
            allow_parallel_requests=False,
            max_queue_time=30.0,
        ),
    ],'''

if old_handlers not in content:
    print(f"ERROR: handlers block not found in {path}", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_handlers, new_handlers, 1)

# 2. 替换 Worker(worker_config).run()，注入 GET 透传路由
old_run = "Worker(worker_config).run()"
new_run = '''import aiohttp as _aiohttp
from aiohttp import web as _web


async def _get_passthrough(request):
    url = f"http://127.0.0.1:18288{request.raw_path}"
    try:
        async with _aiohttp.ClientSession() as _sess:
            async with _sess.get(url) as _resp:
                _body = await _resp.read()
                _ct = _resp.content_type or "application/json"
                return _web.Response(body=_body, status=_resp.status, content_type=_ct)
    except Exception as _e:
        return _web.Response(text=str(_e), status=502)


_worker = Worker(worker_config)
_worker.routes.append(_web.get("/result/{request_id}", _get_passthrough))
_worker.routes.append(_web.get("/health", _get_passthrough))
_worker.routes.append(_web.get("/queue-info", _get_passthrough))
_worker.run()'''

if old_run not in content:
    print(f"ERROR: Worker(worker_config).run() not found in {path}", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_run, new_run, 1)

with open(path, "w") as f:
    f.write(content)
print(f"✓ pyworker patched: /generate/async + GET passthrough added to {path}")
PYEOF

    local py_exit=$?
    if [[ $py_exit -eq 0 ]]; then
        log "✓ patch_pyworker: worker.py 已打补丁（生效于 pyworker 下次重启时）"
        # 注意：不在此处 pkill，因为 start_server.sh 重启时会重新 git clone pyworker 覆盖补丁。
        # 补丁通过 /workspace/.pyworker_patched marker 做幂等保护，实际生效依赖 api-wrapper 降级。
        touch /workspace/.pyworker_patched
    else
        log "[WARN] patch_pyworker: Python 补丁失败 (exit $py_exit)"
    fi
}

update_comfyui() {
    # 更新 ComfyUI 到最新合并提交以获得 WanVideoToVideo 等新节点支持。
    # 当前 Docker 镜像内置版本为 0.7.0 (2025-12-30)，缺少 Wan 2.2 Animate 内置节点。
    local comfyui_dir="/workspace/ComfyUI"
    local marker="${comfyui_dir}/.comfyui_updated"

    if [[ -f "$marker" ]]; then
        log "update_comfyui: ComfyUI 已是最新版，跳过"
        return 0
    fi

    log "update_comfyui: 更新 ComfyUI..."
    cd "$comfyui_dir" || { log "[WARN] update_comfyui: 无法进入 $comfyui_dir，跳过"; return 0; }

    local before_commit
    before_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    # 用 checkout -B 处理 detached HEAD 情况（git pull --ff-only 在 detached HEAD 上会报错）
    git fetch origin master 2>&1 | tee -a "$MODEL_LOG" || true
    git checkout -B master origin/master 2>&1 | tee -a "$MODEL_LOG" || true
    local after_commit
    after_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    if [[ "$before_commit" == "$after_commit" ]]; then
        log "update_comfyui: 已是最新提交 ($after_commit)，无需重启"
        touch "$marker"
        return 0
    fi

    log "update_comfyui: 已更新 $before_commit → $after_commit，重启 ComfyUI..."
    supervisorctl restart comfyui 2>&1 | tee -a "$MODEL_LOG" || true
    touch "$marker"
    log "✓ update_comfyui: ComfyUI 已更新并重启"
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

    # 安装 VideoHelperSuite（提供 VHS_LoadVideo，V2V 工作流必须）
    local vhs_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-VideoHelperSuite"
    if [ ! -d "$vhs_dir" ]; then
        log "Installing ComfyUI-VideoHelperSuite..."
        git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "$vhs_dir"
        if [ -f "$vhs_dir/requirements.txt" ]; then
            pip install -q -r "$vhs_dir/requirements.txt" 2>&1 | tee -a "$MODEL_LOG"
        fi
        log "✓ VideoHelperSuite installed"
    else
        log "VideoHelperSuite already installed, skipping"
    fi

    # 更新 ComfyUI 到最新版本（获取 WanVideoToVideo 等 Wan 2.2 标准节点）
    update_comfyui

    # 后台等待各组件安装完毕后自动打补丁，不阻塞模型下载
    patch_ws_timeout &
    patch_api_wrapper &
    patch_pyworker &

    write_api_workflow
    set_cleanup_job

    # ── 模型下载 ──────────────────────────────────────────────────────────────
    # 有了 HF_TOKEN 后速度 200-500MB/s，全套 ~95GB 约 5-10 分钟，
    # 全部同步下载完再退出，实例 benchmark 通过时所有模型均已就绪。
    log "Downloading all models (~95GB total, up to ${HF_MAX_PARALLEL} parallel)..."
    local all_pids=()
    for model in "${HF_MODELS[@]}"; do
        local _url _out
        _url="${model%%|*}"; _url=$(echo "$_url" | xargs)
        _out="${model##*|}"; _out=$(echo "$_out" | xargs)
        download_hf_file "$_url" "$_out" &
        all_pids+=($!)
    done
    for item in "${WGET_DOWNLOADS[@]}"; do
        [[ -z "${item// }" ]] && continue
        local _url _out
        _url="${item%%|*}"; _url=$(echo "$_url" | xargs)
        _out="${item##*|}"; _out=$(echo "$_out" | xargs)
        download_wget_file "$_url" "$_out" &
        all_pids+=($!)
    done
    for _pid in "${all_pids[@]}"; do wait "$_pid" || true; done
    log "✓ All models downloaded. Provisioning complete."
}

main