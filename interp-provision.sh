#!/bin/bash
# 补帧(frame interpolation 60fps) provisioning —— 用作 vast comfy 模板的 PROVISIONING_SCRIPT。
# 照 vc-provision.sh / h3-provision.sh 的骨架写，跑在 vastai/comfy 镜像上
# （/workspace/ComfyUI + /venv/main + supervisord）。
#
# 这个工作流【不需要装任何自定义节点包】：LoadVideo/SaveVideo/CreateVideo/
# GetVideoComponents/FrameInterpolationModelLoader/FrameInterpolate 在 ComfyUI 0.27.0
# 已全部原生内置（实测 /object_info，不是 Fannovel16 那个三方包）。所以只做一件事：
#   下 rife_v4.26.safetensors(22.7MB) 到 models/frame_interpolation/ 并校验。
# 没有 pip 依赖、不碰 torch，所以不需要 constraints 护栏，也不需要重启 comfyui
# （provisioning 门控保证 ComfyUI 在本脚本跑完后才首次启动、届时会扫到模型）。
# 完成后 vast 的 75-provisioning-manifest.sh 会写 /.provisioning_complete。
#
# 故意不用 set -e：下载失败该重试而不是中断。
set -uo pipefail

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
CU="${WORKSPACE_DIR}/ComfyUI"
MODELS="${CU}/models"
INTERP="${MODELS}/frame_interpolation"
# 独立日志（别写 comfyui.log，supervisor 重启会把它轮转掉）；stdout 另被 vast 收进
# /var/log/portal/provisioning.log。
LOG="${INTERP_PROVISION_LOG:-/var/log/portal/interp-provision.log}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

PY=/venv/main/bin/python
PIP=/venv/main/bin/pip

# ── 模型清单：(HF仓库, 仓库内路径, 落位目录) ──────────────────────────────────
# ⚠️ 文件在仓库的 frame_interpolation/ 子目录下，下载路径必须带该前缀（根目录没有→404）。
# --local-dir 用 models：hf 会保留仓库子目录结构 → 正好落到 models/frame_interpolation/。
MODEL_SPECS=(
  "Comfy-Org/frame_interpolation|frame_interpolation/rife_v4.26.safetensors|${MODELS}"   # 22.7MB RIFE 权重
)

# ── hf CLI（vast 装在 provisioner venv，系统 PATH 里未必有）+ 下载加速 ────────
setup_hf() {
  if ! command -v hf >/dev/null 2>&1; then
    export PATH="/opt/instance-tools/provisioner/venv/bin:/venv/main/bin:$PATH"
  fi
  HF_BIN="$(command -v hf || echo /venv/main/bin/hf)"
  HF_DIR="$(dirname "$HF_BIN")"
  "$HF_DIR/pip" install -q -U hf_transfer hf_xet >/dev/null 2>&1 || $PIP install -q -U hf_transfer hf_xet >/dev/null 2>&1 || true
  export HF_XET_HIGH_PERFORMANCE=1
  if "$HF_DIR/python" -c "import hf_transfer" >/dev/null 2>&1 || $PY -c "import hf_transfer" >/dev/null 2>&1; then
    export HF_HUB_ENABLE_HF_TRANSFER=1
    log "下载加速: hf_transfer + hf_xet 已启用"
  else
    log "下载加速: 仅 hf_xet（hf_transfer 不可用，跳过以免 hf 报错）"
  fi
}

download_one() {
  local repo="$1" f="$2" dir="$3" dest="$3/$2" attempt=1 max=5 delay=4
  if [ -s "$dest" ]; then log "已存在，跳过: $f"; return 0; fi
  mkdir -p "$dir"
  while [ $attempt -le $max ]; do
    log "下载 $repo/$f (第 $attempt/$max 次)..."
    if "$HF_BIN" download "$repo" "$f" --local-dir "$dir" 2>&1 | tail -2 | tee -a "$LOG"; then
      [ -s "$dest" ] && { log "✓ $f"; return 0; }
    fi
    log "✗ $f 失败，${delay}s 后重试..."; sleep $delay; delay=$((delay*2)); attempt=$((attempt+1))
  done
  log "[ERROR] 放弃: $repo/$f（$max 次都失败）"; return 1
}

main() {
  log "===== 补帧 provisioning 开始 ====="
  [ -f /venv/main/bin/activate ] && . /venv/main/bin/activate
  [ -d "$CU" ] || { log "[ERROR] 找不到 $CU —— 镜像不对？"; return 1; }
  command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python3 || command -v python)"

  setup_hf
  local n_fail=0
  for spec in "${MODEL_SPECS[@]}"; do
    IFS='|' read -r repo path dir <<< "$spec"
    download_one "$repo" "$path" "$dir" || n_fail=$((n_fail+1))
  done

  # 校验：文件在位且体积合理(>1MB)。rife_v4.26 ~22.7MB。
  local m="${INTERP}/rife_v4.26.safetensors"
  if [ -s "$m" ] && [ "$(stat -c%s "$m" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    log "✓ 模型就位: $m ($(du -h "$m" | cut -f1))"
  else
    log "[ERROR] 模型缺失或体积异常: $m"; n_fail=$((n_fail+1))
  fi

  if [ "$n_fail" -eq 0 ]; then
    log "===== 补帧 provisioning 完成 ✓ ====="
  else
    log "===== 补帧 provisioning 有 $n_fail 处失败，见上 ====="
  fi
}

main "$@"
