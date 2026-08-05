#!/bin/bash
# H3 图文生视频(ref2va) provisioning 脚本 —— 用作 vast comfy 模板的 PROVISIONING_SCRIPT。
# 照 wan-2.2-14b 脚本的下载骨架，H3 专用：升级 ComfyUI 到含 H3 节点的 v0.30 + 下 int8 出片集 + 重启。
# 走 AVPE 的 SSH 隧道用，不需要 serverless 的 api-wrapper/pyworker 补丁，故全部去掉。
#
# --disable-dynamic-vram 由模板的 COMFYUI_ARGS 注入（开机即带），不在此脚本里改 comfyui.sh。
# 完成后 vast 的 75-provisioning-manifest.sh 会写 /.provisioning_complete，租机脚本据此判就绪。
#
# 故意不用 set -e：单个模型失败不该中断整个 provisioning。
set -uo pipefail

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
CU="${WORKSPACE_DIR}/ComfyUI"
MODELS="${CU}/models"
LOG="${MODEL_LOG:-/var/log/portal/comfyui.log}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# H3 int8 出片集（== AVPE h3_i2v_api.json 实际用的）。仓库路径，落位到 $MODELS/<路径>。
# 公开仓库，不需要 HF_TOKEN；如模板里设了 HF_TOKEN 会自动用（解除匿名限速、下得更快）。
HF_REPO="Comfy-Org/MiniMax-H3"
H3_FILES=(
  "diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors"   # int8 DiT ~34G
  "text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors"         # bf16 TE ~51.5G
  "vae/minimax_h3_video_vae_fp16.safetensors"                     # ~5.2G
  "vae/minimax_h3_audio_vae_fp32.safetensors"                     # ~0.6G
)
# 想额外要 bf16 DiT 做 UNETLoader 下拉 parity，把下面这行取消注释（多 66G、多下几分钟）：
# H3_FILES+=("diffusion_models/minimax_h3_ref2va_bf16.safetensors")

# hf CLI：vast 把它装在 provisioner venv，系统 PATH 里未必有
if ! command -v hf >/dev/null 2>&1; then
  export PATH="/opt/instance-tools/provisioner/venv/bin:/venv/main/bin:$PATH"
fi
HF_BIN="$(command -v hf || echo /venv/main/bin/hf)"

download_one() {
  local f="$1" dest="$MODELS/$f" attempt=1 max=5 delay=4
  if [ -s "$dest" ]; then log "已存在，跳过: $f"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  while [ $attempt -le $max ]; do
    log "下载 $f (第 $attempt/$max 次)..."
    if "$HF_BIN" download "$HF_REPO" "$f" --local-dir "$MODELS" 2>&1 | tail -3 | tee -a "$LOG"; then
      [ -s "$dest" ] && { log "✓ $f"; return 0; }
    fi
    log "✗ $f 失败，${delay}s 后重试..."; sleep $delay; delay=$((delay*2)); attempt=$((attempt+1))
  done
  log "[ERROR] 放弃: $f（$max 次都失败）"; return 1
}

main() {
  log "===== H3 provisioning 开始 ====="
  [ -f /venv/main/bin/activate ] && . /venv/main/bin/activate

  # 1) 升级 ComfyUI 到 v0.30.0（H3 原生节点 nodes_minimax_h3.py 所在版本）
  log "升级 ComfyUI -> v0.30.0"
  cd "$CU" || { log "[ERROR] 进不去 $CU"; return 1; }
  git fetch --tags --force 2>&1 | tail -1 | tee -a "$LOG" || true
  git checkout v0.30.0 2>&1 | tail -1 | tee -a "$LOG" || true
  /venv/main/bin/pip install -q -r requirements.txt 2>&1 | tail -2 | tee -a "$LOG" || true
  if [ -f "$CU/comfy_extras/nodes_minimax_h3.py" ]; then
    log "✓ H3 节点存在"
  else
    log "[ERROR] H3 节点缺失（checkout v0.30 失败？）——工作流会报 node 缺失"
  fi

  # 2) 下 int8 出片集（hf download 自动处理 HF 的 Xet 重定向 + 大文件）
  log "下模型（int8 集，约 92G）..."
  local failed=0
  for f in "${H3_FILES[@]}"; do download_one "$f" || failed=$((failed+1)); done

  # 3) 重启 comfyui 刷新 UNETLoader/CLIPLoader 列表（新下的模型才认得出）
  supervisorctl restart comfyui 2>&1 | tail -1 | tee -a "$LOG" || true

  # 4) 校验
  local ok=1
  for f in "${H3_FILES[@]}"; do
    if [ -s "$MODELS/$f" ]; then log "OK  $f ($(du -h "$MODELS/$f" 2>/dev/null | cut -f1))"
    else log "[ERROR] 缺 $f"; ok=0; fi
  done
  if [ "$failed" -gt 0 ] || [ "$ok" -ne 1 ]; then
    log "[ERROR] 有模型没下成，provisioning 视为失败"; return 1
  fi
  log "===== ✓ H3 provisioning 完成，模型齐全 ====="
}

main
