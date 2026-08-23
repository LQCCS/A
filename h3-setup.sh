#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# h3-setup.sh —— H3 装机精简版：**只做 下模型 + 装节点 + 改配置 + 重启**。
#
# 用法（在实例上直接跑，一把梭）：
#   bash <(curl -sL https://raw.githubusercontent.com/LQCCS/A/main/h3-setup.sh)
#   # 默认 = bf16 全套 123.6G + SageAttention + Spectrum。切 int8 跑量 / 关加速：
#   H3_DIT_FILE=diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors bash <(curl -sL ...)
#   NO_SAGE=1 NO_SPECTRUM=1 bash <(curl -sL ...)
#
# 与 h3-provision.sh 的区别：那个是 vast 的 PROVISIONING_SCRIPT（开机自动跑、只管下模型）；
# 这个是**手动跑的全套**，把原来散在 rent_h3_instance.py 里的"装节点/编译 Sage/校正启动参数/重启"
# 一并收进来，不含选机/租机/冒烟出片/测速。已装的部分全部幂等秒过，可反复跑。
#   —— 冒烟出片仍然**不在这里**：它归 rent_h3_instance.py 的步骤 7（那儿有参考图和计时逻辑）。
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
PROC_DIR="${PROC_DIR:-/proc}"              # 同上：步骤 7 靠 $PROC_DIR/<pid>/cmdline 核实生效参数
API_BASE="${API_BASE:-http://127.0.0.1:18188}"   # 同上：步骤 6/7 探活与节点查询
COMFY_VERSION="${COMFY_VERSION:-v0.30.0}"
HF_REPO="Comfy-Org/MiniMax-H3"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

FAILED=0
step() { echo; log "══════ $1 ══════"; }

# ── 模型清单（HF 精确字节数，下完只认精确匹配；下载中断留下的半截文件也非空，光看 -s 不够）──
# DiT 由 H3_DIT_FILE 指定（逗号分隔 1~2 个）。
# 默认改为 **bf16（66.3G，零损失原版精度）**：用户 2026-08-22 定"直接换成 bf16"，
# 全套 = bf16 DiT 66.3G + bf16 TE 51.5G + VAE 5.8G = 123.6G，盘需 ≥180G。
# 想回 int8 跑量：H3_DIT_FILE=diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors
IFS=',' read -ra _DITS <<< "${H3_DIT_FILE:-diffusion_models/minimax_h3_ref2va_bf16.safetensors}"
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
file_complete() {
  local f="$1" expected got
  expected="$(expected_bytes "$f")" || return 1
  [ -f "$MODELS/$f" ] || return 1
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
  local expected got part_got attempt=1 max=4 delay=4
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
      timeout 3600 aria2c --continue=true --max-connection-per-server=16 --split=16 \
          --min-split-size=8M --max-tries=1 --timeout=30 --connect-timeout=30 \
          --lowest-speed-limit=1M --allow-overwrite=false --auto-file-renaming=false \
          --summary-interval=20 --console-log-level=warn \
          --dir "$(dirname "$part")" --out "$(basename "$part")" "$url" 2>&1 \
        | stdbuf -oL tr '\r' '\n' \
        | stdbuf -oL grep -E '^\[#|\(OK\)|ERR|error' \
        | stdbuf -oL tee -a "$LOG" || true
      got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
      if [ "$got" = "$expected" ]; then
        rm -f "$part.aria2"; mv "$part" "$dest"; log "✓ $f ($got B, aria2c)"; return 0
      fi
      rm -f "$part.aria2"      # 留着会让 curl 的 -C - offset 与控制文件对不上
      log "aria2c 未完整 ($got/$expected)，本轮转 curl 兜底…"
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
step "步骤 4 · KJNodes + SageAttention + Spectrum"
mkdir -p "$(dirname "$SAGE_LOG")"; : >> "$SAGE_LOG"
cd "$CU/custom_nodes" || { log "[ERROR] 进不去 custom_nodes"; FAILED=$((FAILED+1)); }
if [ -d ComfyUI-KJNodes ]; then
  log "KJNodes 已存在"
else
  log "clone KJNodes…"
  git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git >>"$SAGE_LOG" 2>&1 || true
  "$PIP" install -q -r ComfyUI-KJNodes/requirements.txt >>"$SAGE_LOG" 2>&1 || true
fi

# ── Spectrum：跳步预测加速（和 Sage 正交，可叠加）─────────────────────────────
# 原理：用切比雪夫岭回归预测 transformer 输出，跳过部分真实评估。
# 作者数据：20 步典型解成 11 次真实评估 + 9 次预测。
# ⚠️ 它是**近似**加速器——README 原话 "output can differ from native H3 even with the
#    same seed"。所以只**装**、不自动接进工作流；要用就在 UI 里把
#    `Spectrum Apply MiniMax H3` 插在 SigmaShift 和 guider 之间。追求零损失就别接。
# ⚠️ 别和 EasyCache/LazyCache 放同一条 model 分支（README:325，Spectrum 会检测到并静默失效）。
# ✅ 不改 attention 后端（README:318），和上面编译的 SageAttention 2.x 可同时开。
# ✅ pyproject dependencies = []，零 pip 依赖，clone 完就能用。
# 版本硬要求核过：它只要 comfy.ldm.minimax.model 有 PackedLayout/unpatchify_video/
#   unpack_audio/time_shift_sigma 四个 helper，v0.30.0 全有（README 那句 "minimum
#   reviewed commit e377e263" 只是作者测试基线：该 commit 与 v0.30.0 之间仅 2 个提交，
#   只动了 model_management.py 和 requirements.txt，H3 模型文件 blob sha 完全相同）。
if [ -n "${NO_SPECTRUM:-}" ]; then
  log "NO_SPECTRUM=1 → 跳过 Spectrum"
elif [ -d ComfyUI-Spectrum-MiniMax-H3/.git ]; then
  log "Spectrum 已存在（$(git -C ComfyUI-Spectrum-MiniMax-H3 rev-parse --short HEAD 2>/dev/null || echo '?')）"
else
  log "clone Spectrum…"
  git clone --depth 1 https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3.git >>"$SAGE_LOG" 2>&1 || true
  if [ -d ComfyUI-Spectrum-MiniMax-H3 ]; then
    # clone 不钉 commit = 供应链漂移；这个 sha 是出问题时唯一的复现锚点，无条件记进日志
    log "✓ Spectrum $(git -C ComfyUI-Spectrum-MiniMax-H3 rev-parse --short HEAD 2>/dev/null || echo '?')"
  else
    log "[WARN] Spectrum clone 失败（不致命，只是没有跳步加速）"
  fi
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
  if curl -sf -o /dev/null --max-time 3 "$API_BASE/system_stats" 2>/dev/null; then
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
# 加速件是软失败项：没装上不判整机不合格，但必须看得见（否则"怎么没变快"无从查起）
# ⚠️ /object_info/<名> 对不存在的节点也返回 200 → 只能查 JSON body 里有没有那个 key
if curl -sf --max-time 15 "$API_BASE/object_info/SpectrumApplyMiniMaxH3" 2>/dev/null \
     | grep -q SpectrumApplyMiniMaxH3; then
  log "  OK   Spectrum 节点已注册（用不用由工作流决定）"
else
  log "  --   Spectrum 节点未注册（NO_SPECTRUM=1 或 clone 失败；不影响出片）"
fi
"$PY" -c "import sageattention" 2>/dev/null \
  && log "  OK   sageattention import 正常" \
  || log "  --   sageattention 不可用 → 回落 SDPA（约慢 1.5-2×）"
# bf16 的命门：这个 flag 在 = 长片必 OOM。步骤 5 改的是 $ENV_FILE，这里查**真实生效**的命令行。
# ⚠️ 必须把"读不到命令行"和"读到了且干净"分开报：合在一起写会让 supervisorctl 失败时
#    grep 无匹配 → 走 else → 打出 "OK DynamicVRAM 开着"，这是**假通过**。
_pid="$(supervisorctl pid comfyui 2>/dev/null | tr -dc '0-9')"
if [ -z "$_pid" ] || [ ! -r "$PROC_DIR/$_pid/cmdline" ]; then
  log "  ??   读不到 comfyui 命令行（pid='${_pid:-空}'）—— DynamicVRAM 状态未知，别当通过"
elif tr '\0' ' ' < "$PROC_DIR/$_pid/cmdline" | grep -q -- '--disable-dynamic-vram'; then
  log "  BAD  --disable-dynamic-vram 仍在生效命令行里 —— bf16 长片会 OOM"; FAILED=$((FAILED+1))
else
  log "  OK   DynamicVRAM 开着（已核实生效命令行，无 --disable-dynamic-vram）"
fi
echo
if [ "$FAILED" -eq 0 ]; then
  log "═══ ✓ 装机完成，模型齐全、服务已起 ═══"
  exit 0
else
  log "═══ ✗ 有 $FAILED 项没过 —— 上面找 [ERROR]/BAD ═══"
  exit 1
fi
