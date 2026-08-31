#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# h3-setup.sh —— H3 装机精简版：**只做 下模型 + 装节点 + 改配置 + 重启**。
#
# 用法（在实例上直接跑，一把梭）：
#   bash <(curl -sL https://raw.githubusercontent.com/LQCCS/A/main/h3-setup.sh)
#   # 选 DiT / 关 Sage：
#   H3_DIT_FILE=diffusion_models/minimax_h3_ref2va_bf16.safetensors NO_SAGE=1 bash <(curl -sL ...)
#
# 与 h3-provision.sh 的区别：那个是 vast 的 PROVISIONING_SCRIPT（开机自动跑、只管下模型）；
# 这个是**手动跑的全套**，把原来散在 rent_h3_instance.py 里的"装节点/编译 Sage/校正启动参数/重启"
# 一并收进来，不含选机/租机/冒烟出片/测速。已装的部分全部幂等秒过，可反复跑。
#
# 故意不用 set -e：单个模型失败不该中断整个装机（末尾统一汇总成败）。
set -uo pipefail

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
CU="${WORKSPACE_DIR}/ComfyUI"
MODELS="${CU}/models"
VENV="${VENV_ROOT:-/venv/main}"
PY="$VENV/bin/python"
PIP="$VENV/bin/pip"
LOG="${MODEL_LOG:-/var/log/portal/comfyui.log}"
SAGE_LOG="${SAGE_LOG:-/var/log/portal/sageattention-build.log}"
ENV_FILE="${ENV_FILE:-/etc/environment}"   # 可覆盖，便于打桩测试（正常别动）
COMFY_VERSION="${COMFY_VERSION:-v0.30.0}"
HF_REPO="Comfy-Org/MiniMax-H3"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

FAILED=0
step() { echo; log "══════ $1 ══════"; }

# ── 模型清单（HF 精确字节数，下完只认精确匹配；下载中断留下的半截文件也非空，光看 -s 不够）──
# DiT 由 H3_DIT_FILE 指定（逗号分隔 1~2 个），不设=int8_convrot。
IFS=',' read -ra _DITS <<< "${H3_DIT_FILE:-diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors}"
H3_FILES=(
  "${_DITS[@]}"
  "text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors"   # bf16 TE ~51.5G
  "vae/minimax_h3_video_vae_fp16.safetensors"               # ~5.2G
  "vae/minimax_h3_audio_vae_fp32.safetensors"               # ~0.6G
)
expected_bytes() {
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
# 🔴 完整性判据 = 精确字节数 **且** 无 aria2 控制文件 / .partial 残留。
#    只看字节数会被 aria2 的 prealloc 骗过（2026-08-21 实测 48277679：
#    stat 得到的字节数与期望值一字节不差，实际只有 80% 真数据 → ComfyUI 采样出 NaN）。
#    aria2 只在真正下完时才自删控制文件，所以它在 = 没下完。
file_complete() {
  local f="$1" expected got
  expected="$(expected_bytes "$f")" || return 1
  [ -f "$MODELS/$f" ] || return 1
  [ -f "$MODELS/$f.aria2" ] && return 1
  [ -f "$MODELS/$f.partial.aria2" ] && return 1
  [ -f "$MODELS/$f.partial" ] && return 1
  got="$(stat -c %s "$MODELS/$f" 2>/dev/null || echo 0)"
  [ "$got" = "$expected" ]
}

# ═══ 步骤 1 · 下载器 ═══════════════════════════════════════════════════════════
# 🔴 全部走 aria2c -x16。2026-08-20 同机实测（实例 48189450，链路 4771Mbps=596MB/s）：
#    aria2c -x16 拉 TE 51.5G = 107s → **481 MB/s（81% 链路）**；DiT 34G = 71s → **479 MB/s**（n=2）
#    同一次装机里 hf download --max-workers 4 = **27 MB/s（4.5%）** → **≈18×**。
#    另 HF 员工（xet-core#592，仍 open）："no reliable way to serve files larger than 50GB
#    over a single HTTP connection" —— TE/bf16 DiT 正好压在这条线上面。
step "步骤 1 · 准备下载器 aria2c"
if command -v aria2c >/dev/null 2>&1; then
  log "aria2c 已就绪：$(aria2c --version 2>/dev/null | head -1)"
else
  log "装 aria2c…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null 2>&1 || true
  command -v aria2c >/dev/null 2>&1 \
    && log "aria2c 装好了" \
    || log "[WARN] aria2c 装不上 → 回落单流 curl（会慢一个数量级）"
fi
[ -n "${HF_TOKEN:-}" ] || log "[提示] 未设 HF_TOKEN：匿名下载会被限速（公开仓库仍可下）。export HF_TOKEN=hf_… 可提速"

download_one() {
  local f="$1"
  local dest="$MODELS/$f" part="$MODELS/$f.partial"
  local url="https://huggingface.co/${HF_REPO}/resolve/main/${f}"
  # A2_RETRY 用 local：aria2 续传计数必须**每个文件重置**（成功时 return 0 不会走到下面那处重置）
  local expected got part_got attempt=1 max=4 delay=4 A2_RETRY=0
  expected="$(expected_bytes "$f")" || { log "[ERROR] 未登记精确字节数: $f"; return 1; }
  if file_complete "$f"; then log "已完整，跳过: $f"; return 0; fi
  mkdir -p "$(dirname "$dest")"

  # 已存在但不完整 → 退回 .partial 续传；比预期大 → 拒绝覆盖（宁可报错也不交出坏文件）
  if [ -f "$dest" ]; then
    got="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    if [ "$got" -lt "$expected" ]; then
      if [ -f "$part" ]; then
        part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$got" -gt "$part_got" ]; then mv -f "$dest" "$part"; else rm -f "$dest"; fi
      else
        mv "$dest" "$part"
      fi
      log "检测到未完整文件，转断点续传: $f ($got/$expected)"
    else
      log "[ERROR] 字节数异常且不可续传: $f ($got/$expected)"; return 1
    fi
  fi
  if [ -f "$part" ]; then
    part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    [ "$part_got" -gt "$expected" ] && { log "[ERROR] 临时文件超预期，拒绝覆盖: $f"; return 1; }
  fi

  while [ $attempt -le $max ]; do
    part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    if command -v aria2c >/dev/null 2>&1; then
      log "aria2c -x16 下载 $f（第 $attempt/$max 次，续传 $part_got/$expected）"
      # 🔴 --summary-interval=20 必须开：aria2 **预分配整个文件**（实测下载中的 .partial：
      #    apparent = 完整大小，blocks×512 也已全满）→ du -sb / du -sB1 **都不能当进度**。
      #    唯一可信的是它自己的 `[#xxxx 12GiB/34GiB(35%) CN:16 DL:480MiB ETA:45s]`。
      #    tr \r \n 把回车刷新拆成行 + stdbuf 行缓冲 → 实时可见。**别接 `| tail -N`**（要等 EOF）。
      #    **也别看管道退出码**：grep 无匹配会退 1，配合 pipefail 把成功误判成失败 → 只认字节数。
      # 🔴 --file-allocation=none：prealloc 会让"文件大小"从第一秒就等于最终大小，
      #    进度、续传偏移、完整性判据全部失去意义。
      timeout 3600 aria2c --continue=true --max-connection-per-server=16 --split=16 \
          --file-allocation=none \
          --min-split-size=8M --max-tries=5 --timeout=30 --connect-timeout=30 \
          --lowest-speed-limit=256K --allow-overwrite=false --auto-file-renaming=false \
          --summary-interval=20 --console-log-level=warn \
          --dir "$(dirname "$part")" --out "$(basename "$part")" "$url" 2>&1 \
        | stdbuf -oL tr '\r' '\n' \
        | stdbuf -oL grep -E '^\[#|\(OK\)|ERR|error' \
        | stdbuf -oL tee -a "$LOG" || true
      got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
      # 🔴 判据两条都要：字节数匹配 **且** aria2 已自删控制文件（只在真下完时才删）。
      #    2026-08-21 实测代价（48277679）：被打断的下载 stat 得到 66280487368
      #    （= 期望值一字节不差）却只有 80% 真数据 → ComfyUI 采样出 NaN →
      #    `avcodec_send_frame() returned 22 ... [aac] Input contains (near) NaN/+-Inf`。
      if [ "$got" = "$expected" ] && [ ! -f "$part.aria2" ]; then
        mv "$part" "$dest"; log "✓ $f ($got B, aria2c)"; return 0
      fi
      # 🔴 aria2 未完成 → .partial 必须丢弃。原注释方向反了：问题不在控制文件，
      #    而在 aria2 -x16 **分段写**（大小 = 最高写入偏移，中间可能是空洞）。
      #    curl --continue-at - 只认文件当前大小 → 从末尾续 → 下 0 字节 →
      #    下面的大小检查通过 → 装上空壳。
      rm -f "$part.aria2" "$part"
      # 🔴 2026-08-31 实测（bf16 66GB，实例日志）：aria2c 因 errorCode=5 "Too slow" 中止时，
      #    字节数已经是 66280487368/66280487368 **完全相等**，却因为控制文件还在被判未完整，
      #    然后这里把 .aria2 一起删掉、转 curl 从 0 重下 66GB。
      #    控制文件是**唯一**记录"哪些片段真的下完了"的东西 —— 删它等于自毁续传能力。
      #    正确做法：控制文件还在就再跑一次 aria2c（--continue=true 会照它补齐缺片），
      #    只有连续几次都补不完，才丢弃转 curl。
      if [ -f "${part}.aria2" ] && [ "${A2_RETRY:-0}" -lt 3 ]; then
        A2_RETRY=$(( ${A2_RETRY:-0} + 1 ))
        log "aria2c 中止但控制文件在 ($got/$expected) → 第 $A2_RETRY/3 次 --continue 续传，不丢分片"
        sleep 5
        continue
      fi
      A2_RETRY=0
      log "aria2c 未完整 ($got/$expected)，丢弃分片、转 curl 从 0 重下…"
    fi
    part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    log "curl 直连下载 $f（第 $attempt/$max 次，续传 $part_got/$expected）"
    # 重试放在循环外层：每次重算续传偏移。curl 自带的 retry 可能复用过期 offset、追加重叠尾巴。
    timeout 1800 curl --fail --location --continue-at - \
      --connect-timeout 30 --speed-time 120 --speed-limit 1048576 \
      --progress-bar --output "$part" "$url" 2>&1 | tail -3 | tee -a "$LOG" || true
    got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    if [ "$got" = "$expected" ]; then
      mv "$part" "$dest"; log "✓ $f ($got B, curl)"; return 0
    fi
    log "✗ $f 未完整 ($got/$expected)，${delay}s 后续传…"
    sleep $delay; delay=$((delay*2)); attempt=$((attempt+1))
  done
  log "[ERROR] 放弃: $f（$max 次都未达到精确字节数）"; return 1
}

# ═══ 步骤 2 · ComfyUI 版本 ═════════════════════════════════════════════════════
# v0.30.0 是含 nodes_minimax_h3.py 的起始版本；**别升到 ≥0.32.0**（有 4× 慢化回归），
# 也别升 0.31（走 ModelSamplingAV 音频路径、社区报噪底高，且历史基准全在 0.30 上不可比）。
step "步骤 2 · ComfyUI → $COMFY_VERSION"
if [ -d "$CU/.git" ]; then
  cur="$(cd "$CU" && git describe --tags 2>/dev/null || echo '?')"
  if [ "$cur" = "$COMFY_VERSION" ]; then
    log "已是 $COMFY_VERSION，跳过"
  else
    log "当前 $cur → checkout $COMFY_VERSION"
    (cd "$CU" && git fetch --tags --force 2>&1 | tail -1 | tee -a "$LOG"
     git checkout "$COMFY_VERSION" 2>&1 | tail -1 | tee -a "$LOG"
     "$PIP" install -q -r requirements.txt 2>&1 | tail -2 | tee -a "$LOG") || true
  fi
else
  log "[ERROR] $CU 不是 git 仓库，跳过版本校正"; FAILED=$((FAILED+1))
fi
if [ -f "$CU/comfy_extras/nodes_minimax_h3.py" ]; then
  log "✓ H3 节点存在"
else
  log "[ERROR] H3 节点缺失（checkout 失败？）——工作流会报 node 缺失"; FAILED=$((FAILED+1))
fi

# ═══ 步骤 3 · 下模型 ═══════════════════════════════════════════════════════════
step "步骤 3 · 下模型（DiT×${#_DITS[@]} + TE + VAE）"
mkdir -p "$MODELS"
exec 9>"$MODELS/.h3-download.lock"
log "等下载锁（防两个安装器同时写同一个 .partial）…"
if ! flock -w "${H3_DOWNLOAD_LOCK_TIMEOUT:-2700}" 9; then
  log "[ERROR] 等下载锁超时"; exit 1
fi
log "已取得下载锁"
for f in "${H3_FILES[@]}"; do
  # 跳过也要出声：`file_complete "$f" || download_one "$f"` 会短路掉 download_one 里那条
  # "已完整，跳过"日志 → 幂等重跑时整步骤零输出，看着像卡住（本脚本的测试就抓到过这点）。
  if file_complete "$f"; then
    log "已完整，跳过: $f ($(stat -c %s "$MODELS/$f") B)"
  else
    download_one "$f" || FAILED=$((FAILED+1))
  fi
done
flock -u 9 || true

# ═══ 步骤 4 · 节点 + SageAttention ═════════════════════════════════════════════
# SageAttention ~1.5-2× 提速且**不改变输出**（jo-nike 独立 A/B：与无加速基线相关性 0.974
# "near-identical"）。唯一需要源码编译的一步（~5-8min），已装则秒过。NO_SAGE=1 可跳过。
# 🔴 cu130 机的坑：编译要 cusparse.h，它在 venv 里不在系统 include → 必须动态找出来塞进 CPATH，
#    否则必炸。架构按本机 compute_cap 定（sm120/sm90 都适配），别写死。
step "步骤 4 · KJNodes + SageAttention"
mkdir -p "$(dirname "$SAGE_LOG")"; : >> "$SAGE_LOG"
cd "$CU/custom_nodes" || { log "[ERROR] 进不去 custom_nodes"; FAILED=$((FAILED+1)); }
if [ -d ComfyUI-KJNodes ]; then
  log "KJNodes 已存在"
else
  log "clone KJNodes…"
  git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git >>"$SAGE_LOG" 2>&1 || true
  "$PIP" install -q -r ComfyUI-KJNodes/requirements.txt >>"$SAGE_LOG" 2>&1 || true
fi
if [ -n "${NO_SAGE:-}" ]; then
  log "NO_SAGE=1 → 跳过 SageAttention（回落 SDPA，约慢 1.5-2×）"
elif "$PY" -c "import importlib.metadata as m,sys,sageattention; sys.exit(0 if m.version('sageattention').startswith('2') else 1)" 2>/dev/null; then
  log "SageAttention 2.x 已装，跳过编译"
else
  log "编译 SageAttention（~5-8min，日志 $SAGE_LOG）…"
  "$PIP" uninstall -y sageattention >>"$SAGE_LOG" 2>&1 || true
  "$PIP" install -q ninja packaging >>"$SAGE_LOG" 2>&1 || true
  INC=$(dirname "$(find "$VENV" -name cusparse.h 2>/dev/null | head -1)")
  CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
  cd "$WORKSPACE_DIR" || exit 1
  [ -d SageAttention ] || git clone --depth 1 https://github.com/thu-ml/SageAttention.git >>"$SAGE_LOG" 2>&1
  cd SageAttention || exit 1
  printf '\n===== build %s (cc=%s inc=%s) =====\n' "$(date -Is)" "$CC" "$INC" >> "$SAGE_LOG"
  build_sage() {
    CUDA_HOME=/usr/local/cuda CPATH="$INC:${CPATH:-}" TORCH_CUDA_ARCH_LIST="$CC" \
      MAX_JOBS=8 EXT_PARALLEL=4 "$PIP" install -e . --no-build-isolation >>"$SAGE_LOG" 2>&1
  }
  if ! build_sage; then
    log "第一次编译失败，5s 后重试一次…"; sleep 5
    build_sage || log "[WARN] SageAttention 编译失败（不致命，回落 SDPA）—— 看 $SAGE_LOG"
  fi
fi
if [ -z "${NO_SAGE:-}" ]; then
  "$PY" -c "import sageattention" 2>/dev/null \
    && log "✓ sageattention import OK" \
    || { log "[WARN] sageattention import 失败 → 会回落 SDPA"; tail -20 "$SAGE_LOG" 2>/dev/null; }
fi

# ═══ 步骤 5 · 校正启动参数 ═════════════════════════════════════════════════════
# 模板里的旧 COMFYUI_ARGS 常带 --highvram / --disable-dynamic-vram → **bf16/15s 直接 OOM**。
# 剥掉它们改用动态显存。sed 幂等，重复跑收敛到同一状态。
step "步骤 5 · 校正 COMFYUI_ARGS（去 --highvram，用动态显存）"
f="$ENV_FILE"
before=$(grep COMFYUI_ARGS "$f" 2>/dev/null)
sed -i "s/ --disable-dynamic-vram//g; s/ --highvram//g" "$f" 2>/dev/null || true
after=$(grep COMFYUI_ARGS "$f" 2>/dev/null)
[ "$before" != "$after" ] && log "参数已改动" || log "参数无需改动"
log "现在是: $after"

# ═══ 步骤 6 · 重启并等服务起来 ═════════════════════════════════════════════════
step "步骤 6 · 重启 ComfyUI 并等 18188"
supervisorctl restart comfyui 2>&1 | tail -1 | tee -a "$LOG" || true
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats 2>/dev/null; then
    log "✓ ComfyUI 已起（18188 就绪，用了 ${i}0s 以内）"; break
  fi
  [ "$i" = 60 ] && { log "[ERROR] 18188 十分钟没起来 —— 看 $LOG"; FAILED=$((FAILED+1)); }
  sleep 10
done

# ═══ 步骤 7 · 汇总 ═════════════════════════════════════════════════════════════
step "步骤 7 · 校验汇总"
for f in "${H3_FILES[@]}"; do
  exp="$(expected_bytes "$f" 2>/dev/null || echo '?')"
  got="$(stat -c %s "$MODELS/$f" 2>/dev/null || echo 0)"
  if [ "$got" = "$exp" ]; then log "  OK   $f ($got B)"
  else log "  BAD  $f ($got/$exp)"; FAILED=$((FAILED+1)); fi
done
echo
if [ "$FAILED" -eq 0 ]; then
  log "═══ ✓ 装机完成，模型齐全、服务已起 ═══"
  exit 0
else
  log "═══ ✗ 有 $FAILED 项没过 —— 上面找 [ERROR]/BAD ═══"
  exit 1
fi
