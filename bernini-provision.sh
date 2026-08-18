#!/bin/bash
# Bernini 带货换人(daihuo_swap) provisioning 脚本 —— 用作 vast comfy 模板的 PROVISIONING_SCRIPT。
# 照 h3-provision.sh 的骨架，Bernini 专用差别有三处（都不是照抄 H3 能得到的）：
#   ① **不升级 ComfyUI**：镜像自带的 v0.27.0 已含 comfy_extras/nodes_bernini.py(BerniniConditioning)
#      与 nodes_context_windows.py(WanContextWindowsManual) —— 2026-08-17 直接拉 v0.27.0 tag 源码核实。
#      H3 那边要 checkout v0.30.0 是因为 nodes_minimax_h3.py 才在 0.30；Bernini 不需要，别乱升
#      (≥0.32.0 有 4× 慢化回归)。
#   ② **多仓库 + 定 revision + 改名**：6 个模型分散在 3 个仓库，其中 Bernini fp8 那对的目录
#      已被 Kijai 从 main 删除，只能按 commit 拉；且 HIGH 在 HF 上叫 Wan22_Bernini_HIGH_...，
#      工作流里写的是 Bernini_HIGH_... → **下完必须改名**，否则 UNETLoader 报找不到。
#   ③ **要装 2 个节点包**：KJNodes(WanVideoNAG/PathchSageAttentionKJ/ImageResizeKJv2/INTConstant)
#      + VideoHelperSuite(VHS_LoadVideo/VHS_VideoCombine)。H3 全 comfy-core，不需要。
#
# 所有字节数均由 HF tree API 于 2026-08-17 核准（非 README 自报、非网页缓存）。
# 故意不用 set -e：单个模型失败不该中断整个 provisioning。
set -uo pipefail

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
CU="${WORKSPACE_DIR}/ComfyUI"
MODELS="${CU}/models"
STAGE="${WORKSPACE_DIR}/.hfstage"
LOG="${MODEL_LOG:-/var/log/portal/comfyui.log}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# Kijai 把 Bernini/ 目录从 main 删了 → 定这个 commit 拉历史版（deploy-notes 已核 sha256）
KIJAI_REV="5890255e5742d12ecf40d159dc01c7d647501c40"

# 清单格式：repo|revision|仓库内路径|落位相对 $MODELS 的路径|精确字节数
# revision 留空 = main。落位路径与仓库路径不同的即"改名/挪位"。
BERNINI_FILES=(
  "Kijai/WanVideo_comfy_fp8_scaled|${KIJAI_REV}|Bernini/Wan22_Bernini_HIGH_fp8_e4m3fn_scaled.safetensors|diffusion_models/Bernini_HIGH_fp8_e4m3fn_scaled.safetensors|15574833216"
  "Kijai/WanVideo_comfy_fp8_scaled|${KIJAI_REV}|Bernini/Bernini_LOW_fp8_e4m3fn_scaled.safetensors|diffusion_models/Bernini_LOW_fp8_e4m3fn_scaled.safetensors|15574833216"
  "Comfy-Org/Wan_2.1_ComfyUI_repackaged||split_files/text_encoders/umt5_xxl_fp16.safetensors|text_encoders/umt5_xxl_fp16.safetensors|11366399385"
  "Comfy-Org/Wan_2.1_ComfyUI_repackaged||split_files/vae/wan_2.1_vae.safetensors|vae/wan_2.1_vae.safetensors|253815318"
  "rzgar/Bernini-R-LightX2V-4step-loras||Bernini-R_LightX2V_high_noise.safetensors|loras/Bernini-R_LightX2V_high_noise.safetensors|1244141856"
  "rzgar/Bernini-R-LightX2V-4step-loras||Bernini-R_LightX2V_low_noise.safetensors|loras/Bernini-R_LightX2V_low_noise.safetensors|1244141856"
)
# 合计 45,258,164,847 B ≈ 42.2 GiB（H3 是 92~163G，别照抄 H3 的盘预算）

# 节点包：仓库 URL|目录名
NODE_PACKS=(
  "https://github.com/kijai/ComfyUI-KJNodes.git|ComfyUI-KJNodes"
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|ComfyUI-VideoHelperSuite"
)

# hf CLI：vast 把它装在 provisioner venv，系统 PATH 里未必有
if ! command -v hf >/dev/null 2>&1; then
  export PATH="/opt/instance-tools/provisioner/venv/bin:/venv/main/bin:$PATH"
fi
HF_BIN="$(command -v hf || echo /venv/main/bin/hf)"
HF_DIR="$(dirname "$HF_BIN")"

# 下载提速（与 h3-provision 同策）：hf_transfer 只在确认可 import 时才开，否则 hf 会因缺包直接报错。
"$HF_DIR/pip" install -q -U hf_transfer hf_xet >/dev/null 2>&1 || pip install -q -U hf_transfer hf_xet >/dev/null 2>&1 || true
export HF_XET_HIGH_PERFORMANCE=1
if "$HF_DIR/python" -c "import hf_transfer" >/dev/null 2>&1 || python -c "import hf_transfer" >/dev/null 2>&1; then
  export HF_HUB_ENABLE_HF_TRANSFER=1
  log "下载加速: hf_transfer + hf_xet 已启用"
else
  log "下载加速: 仅 hf_xet（hf_transfer 不可用，跳过以免 hf 报错）"
fi

# 下一个文件：先下到 $STAGE（保仓库目录结构），再挪到 $MODELS/<落位路径>。
# 挪位而非直接 --local-dir $MODELS，是因为 6 个文件里 4 个的仓库路径 ≠ ComfyUI 目录布局。
download_one() {
  local repo="$1" rev="$2" src="$3" dst_rel="$4" want="$5"
  local dest="$MODELS/$dst_rel" attempt=1 max=5 delay=4
  if [ -s "$dest" ]; then
    local have; have=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    if [ "$have" = "$want" ]; then log "已存在且字节数对，跳过: $dst_rel"; return 0; fi
    log "⚠️ $dst_rel 已存在但字节数不符（$have != $want）→ 删掉重下"
    rm -f "$dest"
  fi
  mkdir -p "$(dirname "$dest")" "$STAGE"
  local revargs=(); [ -n "$rev" ] && revargs=(--revision "$rev")
  while [ $attempt -le $max ]; do
    log "下载 $src ← $repo${rev:+ @${rev:0:7}} (第 $attempt/$max 次)..."
    if "$HF_BIN" download "$repo" "$src" "${revargs[@]}" --local-dir "$STAGE" 2>&1 | tail -3 | tee -a "$LOG"; then
      if [ -s "$STAGE/$src" ]; then
        local got; got=$(stat -c %s "$STAGE/$src" 2>/dev/null || echo 0)
        if [ "$got" != "$want" ]; then
          log "✗ $src 字节数不符（$got != $want，可能下到半截/仓库变了）→ 重试"
          rm -f "$STAGE/$src"
        else
          mv -f "$STAGE/$src" "$dest" && { log "✓ $dst_rel"; return 0; }
        fi
      fi
    fi
    log "✗ $src 失败，${delay}s 后重试..."; sleep $delay; delay=$((delay*2)); attempt=$((attempt+1))
  done
  log "[ERROR] 放弃: $src（$max 次都失败）"; return 1
}

install_nodes() {
  mkdir -p "$CU/custom_nodes"; cd "$CU/custom_nodes" || return 1
  local spec url dir
  for spec in "${NODE_PACKS[@]}"; do
    url="${spec%%|*}"; dir="${spec##*|}"
    if [ -d "$dir" ]; then log "节点包已在: $dir"; continue; fi
    log "clone 节点包: $dir"
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -1 | tee -a "$LOG"
    if [ -f "$dir/requirements.txt" ]; then
      /venv/main/bin/pip install -q -r "$dir/requirements.txt" 2>&1 | tail -2 | tee -a "$LOG" || true
    fi
  done
}

main() {
  log "===== Bernini 换人 provisioning 开始 ====="
  [ -f /venv/main/bin/activate ] && . /venv/main/bin/activate

  # 1) 核对 ComfyUI 自带节点（**不升级**，只确认镜像这版够用）
  if [ -f "$CU/comfy_extras/nodes_bernini.py" ]; then
    log "✓ BerniniConditioning 在（comfy-core，不需升级 ComfyUI）"
  else
    log "[ERROR] 缺 comfy_extras/nodes_bernini.py —— 镜像 ComfyUI 版本过旧，工作流会报节点缺失"
  fi
  if [ -f "$CU/comfy_extras/nodes_context_windows.py" ]; then
    log "✓ WanContextWindowsManual 在（撑无限时长靠它）"
  else
    log "[ERROR] 缺 comfy_extras/nodes_context_windows.py —— 长视频会 OOM/接不上"
  fi

  # 2) 装节点包（KJNodes + VHS）。放在下模型**前面**：clone 只有几十 MB、几秒钟，
  #    先装完 ComfyUI 重启一次就能认全，省得下完 42G 才发现节点缺。
  install_nodes

  # 3) 下模型（6 个，3 个仓库，其中 Bernini fp8 定 revision + 改名）
  log "下模型（Bernini HIGH/LOW fp8 + umt5_xxl_fp16 + wan2.1 VAE + LightX2V 高低 LoRA ≈42.2GiB）..."
  local failed=0 entry
  for entry in "${BERNINI_FILES[@]}"; do
    IFS='|' read -r repo rev src dst want <<< "$entry"
    download_one "$repo" "$rev" "$src" "$dst" "$want" || failed=$((failed+1))
  done
  rm -rf "$STAGE" 2>/dev/null || true

  # 4) 重启 comfyui 刷新 UNETLoader/CLIPLoader/LoraLoader 列表 + 加载新节点包
  supervisorctl restart comfyui 2>&1 | tail -1 | tee -a "$LOG" || true

  # 5) 校验（按字节数，不只看存在）
  local ok=1 entry2
  for entry2 in "${BERNINI_FILES[@]}"; do
    IFS='|' read -r repo rev src dst want <<< "$entry2"
    if [ -s "$MODELS/$dst" ]; then
      have=$(stat -c %s "$MODELS/$dst" 2>/dev/null || echo 0)
      if [ "$have" = "$want" ]; then log "OK  $dst ($(du -h "$MODELS/$dst" 2>/dev/null | cut -f1))"
      else log "[ERROR] $dst 字节数不符 $have != $want"; ok=0; fi
    else log "[ERROR] 缺 $dst"; ok=0; fi
  done
  for spec in "${NODE_PACKS[@]}"; do
    dir="${spec##*|}"
    [ -d "$CU/custom_nodes/$dir" ] && log "OK  节点包 $dir" || { log "[ERROR] 缺节点包 $dir"; ok=0; }
  done
  # ffmpeg：VHS_VideoCombine 出片要它；镜像一般自带，缺了这里就报出来（否则出片最后一步才炸）
  command -v ffmpeg >/dev/null 2>&1 && log "OK  ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)" \
    || log "[WARN] 没有 ffmpeg —— VHS_VideoCombine 存 mp4 会失败（VHS 自带 imageio-ffmpeg 可能兜底）"

  if [ "$failed" -gt 0 ] || [ "$ok" -ne 1 ]; then
    log "[ERROR] 有东西没装齐，provisioning 视为失败"; return 1
  fi
  log "===== ✓ Bernini provisioning 完成（模型 6/6 + 节点包 2/2）====="
}

main
