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

# Hugging Face 仓库元数据给出的精确字节数。下载完成不能只看 -s：中断留下的半截文件也非空。
h3_expected_bytes() {
  case "$1" in
    diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors)        echo 34038894550 ;;
    diffusion_models/minimax_h3_ref2va_bf16.safetensors)                echo 66280487368 ;;
    diffusion_models/minimax_h3_ref2va_pruned_bf16.safetensors)         echo 40225724176 ;;
    diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors) echo 20970379616 ;;
    diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors)   echo 20958205608 ;;
    text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors)              echo 51506295256 ;;
    vae/minimax_h3_video_vae_fp16.safetensors)                           echo 5207808496 ;;
    vae/minimax_h3_audio_vae_fp32.safetensors)                           echo 605254808 ;;
    *) return 1 ;;
  esac
}

h3_file_complete() {
  local f="$1"
  local expected got
  expected="$(h3_expected_bytes "$f")" || return 1
  [ -f "$MODELS/$f" ] || return 1
  got="$(stat -c %s "$MODELS/$f" 2>/dev/null || echo 0)"
  [ "$got" = "$expected" ]
}

# 🔴 huggingface_hub 的普通下载路径**硬拒 >50GB 的单文件**（Xet 已被我们关掉，见下）。
# 2026-08-20 实测（实例 48185148）：把 TE(51.5G) 一起交给 `hf download` 并行批次 →
#   `Fetching 4 files: 25%|██▌ | 1/4 [07:22]` 后抛
#   `Error: Invalid value. The file is too large to be downloaded using the regular download method.`
#   → **整批中断**，只完成 1/4，剩下的全退化成逐个串行 curl，白白丢掉并行。
# ⚠️ 报错里劝你 `pip install hf_xet` —— **别听**：Xet 正是我们实测卡死在 99.1% 的东西（见下方 ①）。
# 正解 = 按大小分流：>HF_MAX_BYTES 的直接走可续传 curl（且彼此并行），≤ 的才交给 hf 并行批次。
HF_MAX_BYTES="${HF_MAX_BYTES:-50000000000}"   # 50 GB（十进制）。当前只有 TE 51.5G / bf16 DiT 66.3G 超线。

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

# ══ 🔴 关掉 Xet，超大文件改走可续传直连（2026-08-19）══════════════════════════
# ① 决定的依据 = **本地实测**（这一条最硬，与下面的机制假说无关）：
#    实例 48068790，同一台机、同一个 66.3G 文件：
#      Xet   → **2/2 卡死在 65.68/66.28 GB(99.1%) 后永不返回**
#              socket CLOSE-WAIT、主线程 futex_wait_queue、38 线程、35min 只 76 次上下文切换；
#              且**不续传**（两个 incomplete 后缀不同），缓存堆了两份 65.7G = 131G 垃圾。
#      非Xet直连 → **1/1 成功，293 MB/s，3分35秒，字节数精确 66,280,487,368**
#    → 关 Xet 不但不慢，反而快 ~2.3×。**这个决定不依赖任何外部解释。**
#
# ② 社区状况：**症状广泛复现，但机制无定论、零维护者确认**（别把任何一条当真理）：
#    · xet-core#789  用户抓包 → "CDN 乱序投递 chunk、TCP 拥塞窗口冻结在 10"。**维护者零回应**。
#    · hub#3580      "stalls at 99-100%"、304MB/s→75.5kB/s（**与我们 99.1% 精确吻合**）。**未定因**。
#                    ⚠️ 该帖明说 `HF_XET_HIGH_PERFORMANCE=1` 和 `=0` **都会发生**，
#                       也**串行/并行都会** → 反证"高并发才触发"这一说。
#    · hub#4223      xet 416 CAS 错误、**exit 0 却留 .incomplete**（"退出码撒谎，只有文件系统是真相"）。
#    三种归因互不相同，都没有官方确认 → **只当作"已知问题"，不当作已解释的问题**。
#
# ③ 关于我 8/18 的改动：曾把 HF_XET_NUM_CONCURRENT_RANGE_GETS 16→32 并加多文件并发。
#    据 hub#3580（高性能开关都犯）看，**那大概率不是本次成因**；但当时"串行没吃满带宽"的诊断
#    确实是错的——瓶颈不是串行，是 Xet 本身。故一并撤销，不再靠调 Xet 并发来提速。
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-300}"   # 大分片建议加长，见 hub#3580
unset HF_XET_HIGH_PERFORMANCE HF_XET_NUM_CONCURRENT_RANGE_GETS 2>/dev/null || true
_HUBVER="$("$HF_DIR/python" -c 'import huggingface_hub as h;print(h.__version__)' 2>/dev/null || echo '?')"
# hf_transfer：huggingface_hub 1.0+ 已**静默忽略**它（Xet 取代）。Xet 关掉后走普通 HTTPS，
# 老版本上 hf_transfer 仍能多流提速，故保留探测；新版上它是空操作，别当成"加速已开启"的证据。
# 关键限制：huggingface_hub 1.18 的普通下载代码会硬拒绝 >50GB；TE=51.5GB、bf16 DiT=66.3GB。
# 因此 hf 只作并行快路径，任何未落盘文件一律由下面 curl 直连兜底，绕开客户端大小门槛。
if "$HF_DIR/python" -c "import hf_transfer" >/dev/null 2>&1 || python -c "import hf_transfer" >/dev/null 2>&1; then
  export HF_HUB_ENABLE_HF_TRANSFER=1
  log "下载: **Xet 已禁用**(xet-core#789 拥塞崩溃) + hf_transfer(hub=${_HUBVER}，1.0+ 上被忽略) timeout=${HF_HUB_DOWNLOAD_TIMEOUT}s"
else
  log "下载: **Xet 已禁用**(xet-core#789 拥塞崩溃)，普通 HTTPS，hub=${_HUBVER} timeout=${HF_HUB_DOWNLOAD_TIMEOUT}s"
fi
# 匿名拉 HF 会被限速（日志里那句 "You are sending unauthenticated requests to the HF Hub"）。
# 仓库是公开的、没 token 也能下，只是慢 → 想提速就在 vast 模板 env 里加 -e HF_TOKEN=hf_xxx。
[ -n "${HF_TOKEN:-}" ] || log "[WARN] 未设 HF_TOKEN：匿名下载会被限速（公开仓库仍可下）。模板加 -e HF_TOKEN=… 可提速"

download_one() {
  local f="$1"
  local dest="$MODELS/$f"
  local part="${dest}.partial"
  local expected got part_got
  local attempt=1 max=4 delay=4
  local url="https://huggingface.co/${HF_REPO}/resolve/main/${f}"

  expected="$(h3_expected_bytes "$f")" || {
    log "[ERROR] 未登记精确字节数: $f"; return 1;
  }
  if h3_file_complete "$f"; then log "已存在且字节数正确，跳过: $f"; return 0; fi
  mkdir -p "$(dirname "$dest")"

  # 若最终路径上是可续传的短文件，先退回 .partial；超大/未知文件不覆盖，避免误伤。
  if [ -f "$dest" ]; then
    got="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    if [ "$got" -lt "$expected" ]; then
      if [ -f "$part" ]; then
        part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$got" -gt "$part_got" ]; then mv -f "$dest" "$part"; else rm -f "$dest"; fi
      else
        mv "$dest" "$part"
      fi
      log "检测到未完整文件，转为断点续传: $f ($got/$expected)"
    else
      log "[ERROR] 文件字节数异常且不可续传: $f ($got/$expected)"; return 1
    fi
  fi

  if [ -f "$part" ]; then
    part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    if [ "$part_got" -gt "$expected" ]; then
      log "[ERROR] 临时文件超过预期，拒绝覆盖: $f ($part_got/$expected)"; return 1
    fi
  fi

  while [ $attempt -le $max ]; do
    part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    log "直连下载 $f (第 $attempt/$max 次，续传 $part_got/$expected)..."
    # Keep retries outside curl: before every attempt we re-read .partial's
    # current size.  curl's internal retry can reuse a stale -C offset and
    # append an overlapping tail after a transient connection failure.
    if timeout 1800 curl --fail --location --continue-at - \
        --connect-timeout 30 --speed-time 120 --speed-limit 1048576 \
        --progress-bar --output "$part" "$url" 2>&1 | tail -3 | tee -a "$LOG"; then
      got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
      if [ "$got" = "$expected" ]; then
        mv "$part" "$dest"
        log "✓ $f ($got B)"
        return 0
      fi
    fi
    got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    log "✗ $f 未完整 ($got/$expected)，${delay}s 后续传..."
    sleep $delay; delay=$((delay*2)); attempt=$((attempt+1))
  done
  log "[ERROR] 放弃: $f（$max 次都未达到精确字节数）"; return 1
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
  mkdir -p "$MODELS"
  exec 9>"$MODELS/.h3-download.lock"
  log "等待 H3 模型下载锁（防多个安装器同时写同一个 .partial）..."
  if ! flock -w "${H3_DOWNLOAD_LOCK_TIMEOUT:-2700}" 9; then
    log "[ERROR] 等待 H3 模型下载锁超时"; return 1
  fi
  log "已取得 H3 模型下载锁"
  local missing=() small=() big=() pids=() sz p
  for f in "${H3_FILES[@]}"; do h3_file_complete "$f" || missing+=("$f"); done
  # 🔴 按大小分流（2026-08-20 修）：>50GB 交给 hf 会让**整批**中断（见 HF_MAX_BYTES 处实测），
  #    所以大文件直接走 download_one 的可续传 curl，且大/小两路**并行**跑，不再互相拖。
  for f in "${missing[@]}"; do
    sz="$(h3_expected_bytes "$f" 2>/dev/null || echo 0)"
    if [ "$sz" -gt "$HF_MAX_BYTES" ]; then big+=("$f"); else small+=("$f"); fi
  done
  if [ ${#big[@]} -gt 0 ]; then
    log "超 $((HF_MAX_BYTES/1000000000))GB 的 ${#big[@]} 个文件走 curl 直连（hf 会拒；彼此并行）：${big[*]}"
    for f in "${big[@]}"; do download_one "$f" & pids+=("$!"); done
  fi
  if [ ${#small[@]} -gt 0 ] && "$HF_BIN" download --help 2>&1 | grep -q -- "--max-workers"; then
    log "并行拉 ${#small[@]} 个 ≤$((HF_MAX_BYTES/1000000000))GB 文件（--max-workers ${H3_DL_WORKERS:-4}）"
    ( "$HF_BIN" download "$HF_REPO" "${small[@]}" --local-dir "$MODELS" \
        --max-workers "${H3_DL_WORKERS:-4}" 2>&1 | tail -4 | tee -a "$LOG" || \
        log "[WARN] hf 并行未全成，转逐个兜底" ) & pids+=("$!")
  elif [ ${#small[@]} -gt 0 ]; then
    log "hf CLI 无 --max-workers（旧版），这 ${#small[@]} 个交给下面逐个兜底"
  fi
  for p in "${pids[@]}"; do wait "$p" || true; done   # 大/小两路都收完再进兜底校验
  local failed=0
  for f in "${H3_FILES[@]}"; do
    h3_file_complete "$f" || download_one "$f" || failed=$((failed+1))
  done
  flock -u 9 || true

  # 3) 重启 comfyui 刷新 UNETLoader/CLIPLoader 列表（新下的模型才认得出）
  supervisorctl restart comfyui 2>&1 | tail -1 | tee -a "$LOG" || true

  # 4) 校验
  local ok=1
  for f in "${H3_FILES[@]}"; do
    local expected got
    expected="$(h3_expected_bytes "$f")" || expected=unknown
    got="$(stat -c %s "$MODELS/$f" 2>/dev/null || echo missing)"
    if h3_file_complete "$f"; then log "OK  $f ($got B)"
    else log "[ERROR] 文件缺失/不完整 $f ($got/$expected)"; ok=0; fi
  done
  if [ "$failed" -gt 0 ] || [ "$ok" -ne 1 ]; then
    log "[ERROR] 有模型没下成，provisioning 视为失败"; return 1
  fi
  log "===== ✓ H3 provisioning 完成，模型齐全 ====="
}

main
