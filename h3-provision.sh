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

# H3 出片集（== AVPE h3_i2v_api.json 用的 TE+VAE + 一个 DiT）。仓库路径，落位到 $MODELS/<路径>。
# 公开仓库，不需要 HF_TOKEN；如模板里设了 HF_TOKEN 会自动用（解除匿名限速、下得更快）。
HF_REPO="Comfy-Org/MiniMax-H3"
# DiT 由 rent 脚本/模板的 -e H3_DIT_FILE 指定（**逗号分隔 1~2 个**，2 个用于同机对照实验）；
# 不设=默认 int8_convrot（保手动起机不受影响）。⚠️ rent 脚本租后还会 SSH 强制校正一次，这里只是快路径。
# 可选: ref2va_int8_convrot(34G) / bf16(66G) / pruned_bf16(40G) / pruned_int8_convrot(21G) / pruned_fp8_scaled(21G)
IFS=',' read -ra _DITS <<< "${H3_DIT_FILE:-diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors}"
H3_FILES=(
  "${_DITS[@]}"                                                    # 选中的 DiT（1~2 个，逗号分隔）
  "text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors"         # bf16 TE ~51.5G
  "vae/minimax_h3_video_vae_fp16.safetensors"                     # ~5.2G
  "vae/minimax_h3_audio_vae_fp32.safetensors"                     # ~0.6G
)

# hf CLI：vast 把它装在 provisioner venv，系统 PATH 里未必有
if ! command -v hf >/dev/null 2>&1; then
  export PATH="/opt/instance-tools/provisioner/venv/bin:/venv/main/bin:$PATH"
fi
HF_BIN="$(command -v hf || echo /venv/main/bin/hf)"
HF_DIR="$(dirname "$HF_BIN")"

# 下载提速：装 hf_transfer/hf_xet 加速器并开启。
# - 高带宽机(多 Gbps)默认单流吃不满链路，hf_transfer 多流并行可快数倍；带宽已饱和的机无副作用。
# - HF_XET_HIGH_PERFORMANCE 对 Xet 后端仓库(H3 即是)加速，缺包时被忽略、无害。
# - HF_HUB_ENABLE_HF_TRANSFER 只在确认 hf_transfer 可 import 时才开，否则 hf 会因缺包直接报错、拖垮下载。
"$HF_DIR/pip" install -q -U hf_transfer hf_xet >/dev/null 2>&1 || pip install -q -U hf_transfer hf_xet >/dev/null 2>&1 || true
export HF_XET_HIGH_PERFORMANCE=1        # Xet 高性能模式：提高并发上限 + 加大缓冲，对 H3(Xet 后端仓库)有效
export HF_XET_NUM_CONCURRENT_RANGE_GETS="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-32}"   # 并发 range 请求，默认 16
# ⚠️ **huggingface_hub 1.0+ 已把 HF_HUB_ENABLE_HF_TRANSFER 静默忽略**（Xet 后端取代了 hf_transfer）。
#    所以下面这行在新版上是**空操作**——保留只为兼容老版本，别再把它当成"加速已开启"的证据。
#    真正起作用的是 Xet 的自适应并发(1→64 流) + 上面两个 HF_XET_* 变量 + 下载时的 --max-workers。
_HUBVER="$("$HF_DIR/python" -c 'import huggingface_hub as h;print(h.__version__)' 2>/dev/null || echo '?')"
if "$HF_DIR/python" -c "import hf_transfer" >/dev/null 2>&1 || python -c "import hf_transfer" >/dev/null 2>&1; then
  export HF_HUB_ENABLE_HF_TRANSFER=1
  log "下载加速: hf_xet(高性能, range=${HF_XET_NUM_CONCURRENT_RANGE_GETS}) + hf_transfer(hub=${_HUBVER}，1.0+ 上被忽略)"
else
  log "下载加速: 仅 hf_xet(高性能, range=${HF_XET_NUM_CONCURRENT_RANGE_GETS})，hub=${_HUBVER}"
fi

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

  # 1) 升级 ComfyUI 到 v0.30.0（H3 原生节点 nodes_minimax_h3.py 起始版本）
  #    ⚠️ 这里只是"快路径"；真正的版本以 rent 脚本的 ensure_comfy_version(COMFY_VERSION 常量) 为准——
  #       本文件托管在 GitHub(PROVISION_URL)，本地改了不 push 就不生效，别只改这里。
  #    **为什么停在 v0.30.0 而不升 v0.32.0（2026-08-17 逐条核实后的决定）**：
  #      v0.32.0 的四条 H3 改动没有一条解决我们的问题——
  #        · "Optimize MiniMax-H3 VAE"(PR #15446) = **省显存**(chunked IO)，PR 正文明说，不是画质修复；
  #          真正的解码劣化 issue #15416(tiled 误差 31.4 vs 参考 4.6) **至今 OPEN、未修**
  #        · "Fix peak memory issue with H3" = 省显存 → 实测 78.6/97.9GB 尚余 19G，无内存问题
  #        · VAEDecodeTiled NestedTensor 崩溃 / tiled audio decode 崩溃 → 都没遇到
  #        · 0.31.1 的 SageAttention sm120 噪声修复 → 触发点 >154k token，我们 92k，不受影响
  #      代价却实在：0.31.0 起走 ModelSamplingAV 音频路径(社区报噪底高)；且现有 62 条基准实测
  #      全在 v0.30.0 上，换版本会让历史数据不可比。→ 有明确需求(如上高分辨率顶过 154k)再升。
  log "升级 ComfyUI -> v0.30.0"
  cd "$CU" || { log "[ERROR] 进不去 $CU"; return 1; }
  git fetch --tags --force 2>&1 | tail -1 | tee -a "$LOG" || true
  git checkout v0.30.0 2>&1 | tail -1 | tee -a "$LOG" || true
  /venv/main/bin/pip install -q -r requirements.txt 2>&1 | tail -2 | tee -a "$LOG" || true
  if [ -f "$CU/comfy_extras/nodes_minimax_h3.py" ]; then
    log "✓ H3 节点存在（ComfyUI $(git describe --tags 2>/dev/null || echo '?')）"
  else
    log "[ERROR] H3 节点缺失（checkout v0.30.0 失败？）——工作流会报 node 缺失"
  fi
  # 注：LegacySampling 音频回退节点只在升到 0.31+ 时才需要（那才有 ModelSamplingAV 回归），
  #     v0.30.0 本身没有该回归，故此处不装。rent 脚本按 COMFY_VERSION 自动判断。

  # 2) 下模型：**多文件并行**（DiT + TE + VAE）
  #    为什么改：实测 47913458 串行下载 151.8G 用 20min = **1.01 Gbps**，
  #    而同批候选机标称下行**中位 2.29 Gbps** → **带宽只用了 ~44%**。
  #    根因：原来是 `for f; do hf download REPO <单文件>; done`，每次只喂一个文件，
  #    `--max-workers`(控制**并发文件数**，默认 8) 完全用不上，Xet 的并发只能在单文件内部使。
  #    改成一次把所有缺的文件交给 hf download，让它跨文件并发。
  #    ⚠️ 旧版 hf CLI 可能没有 --max-workers → 先探测，没有就直接走下面的逐个兜底。
  #    ⚠️ 兜底保留：并行跑完后仍逐个检查，缺谁就用 download_one 单独补（含 5 次退避重试）。
  log "下模型（DiT×${#_DITS[@]} + TE + VAE）— 并行..."
  local missing=()
  for f in "${H3_FILES[@]}"; do [ -s "$MODELS/$f" ] || missing+=("$f"); done
  if [ ${#missing[@]} -gt 0 ] && "$HF_BIN" download --help 2>&1 | grep -q -- "--max-workers"; then
    log "并行拉 ${#missing[@]} 个文件（--max-workers ${H3_DL_WORKERS:-4}）"
    "$HF_BIN" download "$HF_REPO" "${missing[@]}" --local-dir "$MODELS" \
      --max-workers "${H3_DL_WORKERS:-4}" 2>&1 | tail -4 | tee -a "$LOG" || \
      log "[WARN] 并行下载未全成，转逐个兜底"
  elif [ ${#missing[@]} -gt 0 ]; then
    log "hf CLI 无 --max-workers（旧版），走逐个串行"
  fi
  local failed=0
  for f in "${H3_FILES[@]}"; do
    [ -s "$MODELS/$f" ] || download_one "$f" || failed=$((failed+1))
  done

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
