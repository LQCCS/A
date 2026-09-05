#!/bin/bash
# Eros Max beta4 provisioning —— 用作 vast comfy 模板的 PROVISIONING_SCRIPT。
#
# 与 h3-provision.sh 的关系：下载骨架（精确字节判据 / aria2→curl 回落 / flock）照搬，
# **模型清单换成 rent_5090_remix.py 那一套**，并新增 LoRA 支持。别把两个脚本混用：
#   h3-provision.sh   下 Comfy-Org 官方 ref2va 三件套，无 LoRA
#   本脚本            下 Eros Max beta4 + 官方 pruned_int8 两份 DiT + TE/VAE + 4 个 LoRA
#
# 装什么与 rent_5090_remix.py 的 ALWAYS_DITS / SHARED_FILES / LORA_SPECS **逐项对应**：
#   diffusion_models/10Eros_Max_h3_TURBO-hybrid_beta4_int8_convrot.safetensors  19.5G  ← 工作流默认 UNET
#   diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors          19.5G  ← 下拉框切换用
#   text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors                       48.0G
#   vae/minimax_h3_video_vae_fp16.safetensors                                    4.8G
#   vae/minimax_h3_audio_vae_fp32.safetensors                                    0.6G
#   loras/ 四个                                                                  0.5G
#   合计 ≈ 99.8 GB（十进制）
#
# 节点包 **0 个**：工作流只用 ComfyUI 核心节点 LoraLoaderModelOnly，
# 所以整段 prefetch_nodes 直接删掉（h3-provision.sh 里那 11 个仓库这边一个都不需要）。
#
# 完成后 vast 的 75-provisioning-manifest.sh 会写 /.provisioning_complete，租机脚本据此判就绪。
# → 所以**失败必须 return 非 0**，否则会被判成"装好了"，拿着缺文件的机器往下跑。
#
# 故意不用 set -e：单个模型失败不该中断整个 provisioning（要走完校验才知道缺哪些）。
set -uo pipefail

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
CU="${WORKSPACE_DIR}/ComfyUI"
MODELS="${CU}/models"
LOG="${MODEL_LOG:-/var/log/portal/comfyui.log}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# rent 脚本的 COMFY_VERSION。这里只是快路径 —— 租后 ensure_comfy_version 还会强制校正一次，
# 本文件托管在 GitHub，本地改了不 push 不生效，**别只改这里**。
COMFY_VERSION="${COMFY_VERSION:-v0.34.2}"

# ══ 清单：local_path|expected_bytes|url1 [url2 ...] ═════════════════════════
# 为什么用一张表而不是 h3-provision.sh 那三个并列的 case（repo / remote_path / bytes）：
# LoRA 走的是**多个互不相干的镜像仓库**，没有"仓库+仓库内路径"这种结构可言，
# 硬套 case 就得再加第四个函数。直接把 URL 列表写进表里，DiT 和 LoRA 用同一套下载器。
# URL 按顺序试，谁先达到精确字节数就用谁。
#
# 字节数来源：HF API tree + Range Content-Range，2026-09-04 复核（与 rent_5090_remix.py 同一批）。
# 🔴 别"顺手"改这些数字：完整性判据只认精确字节，改错一位会让下好的文件被判残缺、无限重下。

HF_MAIN="https://huggingface.co"

SPECS=(
  # ── DiT ×2（ALWAYS_DITS）────────────────────────────────────────────────
  # Eros Max beta4 int8：作者 euler/simple 6-8 步，turbo 已烘焙进权重
  "diffusion_models/10Eros_Max_h3_TURBO-hybrid_beta4_int8_convrot.safetensors|20967637320|${HF_MAIN}/TenStrip/10Eros-Max/resolve/main/10Eros_Max_h3_TURBO-hybrid_beta4_int8_convrot.safetensors"
  # 官方 pruned_int8_convrot（= CivitAI 3193385 REF2VA INT8 Pruned，同 SHA256），用来在下拉框里切换对照
  "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors|20970379616|${HF_MAIN}/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"

  # ── TE / VAE（SHARED_FILES）─────────────────────────────────────────────
  # 🔴 TE 51.5GB > 50GB：huggingface_hub 的普通下载路径**硬拒**这个大小，所以这里
  #    一律走 aria2/curl 直连，不经 hf CLI（h3-provision.sh 的 HF_MAX_BYTES 那段实测结论）。
  "text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors|51506295256|${HF_MAIN}/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors"
  "vae/minimax_h3_video_vae_fp16.safetensors|5207808496|${HF_MAIN}/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors"
  "vae/minimax_h3_audio_vae_fp32.safetensors|605254808|${HF_MAIN}/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors"

  # ── LoRA ×4（LORA_SPECS）────────────────────────────────────────────────
  # CivitAI 要登录才能下，所以全走公开 HF 镜像；每个给多个镜像，按顺序试到字节数对上。
  # VBVR H3 V1（CivitAI 2497207@3220766）SHA256 372597997f64…
  "loras/VBVR_H3_attn_only.safetensors|32826752|${HF_MAIN}/Patarapoom/h3-vbvr/resolve/main/loras/VBVR_H3_attn_only.safetensors ${HF_MAIN}/kirk86413/vbrv1-h3/resolve/main/VBVR_H3_attn_only.safetensors ${HF_MAIN}/ACCC1380/reasoning_lora_vbvr/resolve/main/VBVR_H3_attn_only.safetensors ${HF_MAIN}/gengenpa08/greun/resolve/main/Minimax/VBVR_H3_attn_only.safetensors"
  # Breast Play & Jiggle v2.0（CivitAI 2856004@3278283）SHA256 18832302cd50…
  "loras/breastplayjiggle_h3_v2.safetensors|298262376|${HF_MAIN}/gengenpa08/greun/resolve/main/Minimax/breastplayjiggle_h3_v2.safetensors ${HF_MAIN}/cdkkkk/setup/resolve/main/h3/breastplayjiggle_h3_v2.safetensors ${HF_MAIN}/HentaiP/model-vault/resolve/main/05_MiniMax_H3_Ecosystem/NSFW_LoRAs/breastplayjiggle_h3_v2.safetensors"
  # HMPussy V1 stills（CivitAI 2846342@3252213）作者口径强度 0.5–0.6
  "loras/Vagina_minimax-h3_epoch20.safetensors|77580008|${HF_MAIN}/cdkkkk/setup/resolve/main/h3/Vagina_minimax-h3_epoch20.safetensors ${HF_MAIN}/HentaiP/model-vault/resolve/main/05_MiniMax_H3_Ecosystem/NSFW_LoRAs/HMPussy-V1_epoch20.safetensors"
  # Pussy spread v0.1（CivitAI 2885332@3261512）落盘名与镜像名不同、哈希相同
  "loras/minimax_h3_pussy_spread_v0.1.safetensors|155110288|${HF_MAIN}/HentaiP/model-vault/resolve/main/05_MiniMax_H3_Ecosystem/NSFW_LoRAs/H3_PussySpread-v01-i2v.safetensors"
)

# H3_DIT_FILE 若指定（rent 脚本会传），把它**追加**成额外的 DiT。
# 仅支持 TenStrip / Comfy-Org 两个仓库的已知档；不认识的就跳过，交给租后的 ensure_dits 补。
# 逗号分隔，与 h3-provision.sh 的约定一致。
extra_dit_url() {
  case "$1" in
    diffusion_models/10Eros_Max_*)  echo "${HF_MAIN}/TenStrip/10Eros-Max/resolve/main/${1##*/}" ;;
    diffusion_models/minimax_h3_*)  echo "${HF_MAIN}/Comfy-Org/MiniMax-H3/resolve/main/$1" ;;
    *) return 1 ;;
  esac
}
extra_dit_bytes() {
  case "$1" in
    diffusion_models/10Eros_Max_h3_TURBO-hybrid_beta4_int8_convrot.safetensors) echo 20967637320 ;;
    diffusion_models/10Eros_Max_h3_TURBO-hybrid_beta4.safetensors)              echo 40222982192 ;;
    diffusion_models/10Eros_Max_h3_TURBO-hybrid_beta3_int8_convrot.safetensors) echo 20975924960 ;;
    diffusion_models/10Eros_Max_h3_TURBO-hybrid_beta3.safetensors)              echo 40228492688 ;;
    diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors)         echo 20970379616 ;;
    diffusion_models/minimax_h3_ref2va_pruned_bf16.safetensors)                 echo 40225724176 ;;
    diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors)                echo 34038894550 ;;
    diffusion_models/minimax_h3_ref2va_bf16.safetensors)                        echo 66280487368 ;;
    diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors)           echo 20958205608 ;;
    *) return 1 ;;
  esac
}

if [ -n "${H3_DIT_FILE:-}" ]; then
  IFS=',' read -ra _EXTRA <<< "$H3_DIT_FILE"
  for _d in "${_EXTRA[@]}"; do
    _d="$(echo "$_d" | tr -d '[:space:]')"
    [ -z "$_d" ] && continue
    # 已在 SPECS 里就不重复加
    _dup=0
    for _s in "${SPECS[@]}"; do [ "${_s%%|*}" = "$_d" ] && _dup=1 && break; done
    [ "$_dup" = 1 ] && continue
    if _u="$(extra_dit_url "$_d")" && _b="$(extra_dit_bytes "$_d")"; then
      SPECS+=("$_d|$_b|$_u")
      log "H3_DIT_FILE 追加额外 DiT: $_d ($_b B)"
    else
      log "[WARN] H3_DIT_FILE 里的 $_d 未登记字节数/仓库，跳过（交给租后 ensure_dits 补）"
    fi
  done
fi

# ══ 下载器 ═════════════════════════════════════════════════════════════════
# 只保留 aria2（默认）与 curl（回落）两档。**故意砍掉 h3-provision.sh 的 hf/hfxet 两档**：
#   · hf   同机实测 27 MB/s（链路 4.5%），aria2 481 MB/s（81%）→ ≈18×，没有存在价值
#   · hfxet 本机 2026-08-18 卡死在 99.1% 且不续传，缓存堆了两份 65.7G 垃圾
# 少两条分支 = 少一半的出错面。要做对照实验请直接用 h3-provision.sh。
H3_DOWNLOADER="${H3_DOWNLOADER:-aria2}"
case "$H3_DOWNLOADER" in
  aria2|curl) ;;
  *) log "[WARN] 本脚本只支持 aria2|curl，收到 $H3_DOWNLOADER → 回落 aria2"; H3_DOWNLOADER=aria2 ;;
esac
if [ "$H3_DOWNLOADER" = "aria2" ]; then
  # `|| true`：开机 apt 锁被占不该拖垮 provisioning；装不上会自动回落 curl。
  command -v aria2c >/dev/null 2>&1 || \
    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null 2>&1) || true
fi
log "下载器: $H3_DOWNLOADER（aria2c=$(command -v aria2c >/dev/null 2>&1 && echo 有 || echo 无)）"

# ══ 完整性判据 ═════════════════════════════════════════════════════════════
# 🔴 = 精确字节数 **且** 没有 aria2 控制文件 / .partial 兄弟文件。
#    只看字节数会被 prealloc 骗过：2026-08-21 实例 48277679，一个被打断的 aria2 下载
#    留下的文件 stat 与期望值一字节不差、却只有 80% 真数据 → ComfyUI 照常加载 →
#    采样出 NaN → SaveVideo 报 `[aac] Input contains (near) NaN/+-Inf`。
#    aria2 **只在成功完成时**自己删控制文件，所以它在 = 没下完。
file_complete() {
  local f="$1" expected="$2" got
  [ -f "$MODELS/$f" ] || return 1
  [ -f "$MODELS/$f.aria2" ] && return 1
  [ -f "$MODELS/$f.partial.aria2" ] && return 1
  [ -f "$MODELS/$f.partial" ] && return 1
  got="$(stat -c %s "$MODELS/$f" 2>/dev/null || echo 0)"
  [ "$got" = "$expected" ]
}

# ══ 单文件下载：多镜像 × (aria2 → curl) × 退避重试 ══════════════════════════
download_one() {
  local f="$1" expected="$2" urls="$3"
  local dest="$MODELS/$f" part="$MODELS/$f.partial"
  local got part_got url
  local attempt=1 max=4 delay=4

  if file_complete "$f" "$expected"; then log "已存在且字节数正确，跳过: $f"; return 0; fi
  mkdir -p "$(dirname "$dest")"

  # 🔴 最终文件旁若有 .aria2 控制文件 → 是一次**直接写最终文件名**的未完成下载
  #    （手工跑 `aria2c -o <最终名>` 会造成）。此时 stat 拿到 prealloc 的满尺寸，
  #    会让下面"字节数异常"分支直接判死。先降级成 .partial 让它能续传。
  if [ -f "${dest}.aria2" ]; then
    log "最终文件旁有 aria2 控制文件（未完成的直写下载），降级为 .partial: $f"
    rm -f "$part" "${part}.aria2"
    mv -f "$dest" "$part" 2>/dev/null || true
    mv -f "${dest}.aria2" "${part}.aria2" 2>/dev/null || true
  fi
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
      log "[WARN] 字节数超出预期，丢弃重下: $f ($got/$expected)"
      rm -f "$dest"
    fi
  fi
  if [ -f "$part" ]; then
    part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    # 超过预期说明这个 .partial 不是同一个文件的（换过镜像/换过档），留着只会越续越错
    [ "$part_got" -gt "$expected" ] && { log "临时文件超预期，丢弃: $f"; rm -f "$part" "${part}.aria2"; }
  fi

  while [ $attempt -le $max ]; do
    for url in $urls; do
      local A2_RETRY=0
      while :; do
        part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$H3_DOWNLOADER" = "aria2" ] && command -v aria2c >/dev/null 2>&1; then
          log "aria2c -x16 下载 $f (第 $attempt/$max 次，续传 $part_got/$expected) <- ${url##*/}"
          # 🔴 --summary-interval=20 必须开：aria2 的 summary 行是**唯一可信的进度来源**。
          #    du 不行 —— 2026-08-20 实例 48277770/48277679 踩过：下载中的 .partial
          #    apparent 与 blocks×512 从第一秒就是满的，租机脚本据此要么报"约剩 0 分钟"
          #    (假完成)、要么报"速率≈0"(假挂死)。
          #    输出链路：tr \r \n 拆开回车刷新 → grep 只留 summary/结果行 → **stdbuf 行缓冲的 tee**
          #    同时写 $LOG 和 stdout（stdout 被 vast 收进 /var/log/provisioning.log，
          #    租机脚本 tail -n 8 就能实时看见）。**别在后面接 `| tail -N`**——那会等 EOF 才吐字。
          # 🔴 --file-allocation=none：别让 aria2 预分配，否则续传偏移与完整性判据全失去意义。
          # ⚠️ 不看管道退出码：grep 没匹配会退出 1，配合 pipefail 会把成功误判成失败。判据只用字节数。
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
          # 判据两条都要：字节数匹配 **且** 控制文件已被 aria2 自己删掉。
          # 别把 rm -f .aria2 放到判断之前 —— 那是先毁证据再判断。
          if [ "$got" = "$expected" ] && [ ! -f "${part}.aria2" ]; then
            mv "$part" "$dest"; log "✓ $f ($got B, aria2c)"; return 0
          fi
          # 🔴 控制文件是**唯一**记录"哪些片段真下完了"的东西 —— 删它等于自毁续传。
          #    2026-08-31 实测（bf16 66GB）：aria2c 因 errorCode=5 "Too slow" 中止时字节数
          #    已经完全相等，却因控制文件还在被判未完整，旧逻辑把 .aria2 一起删了转 curl
          #    从 0 重下 66GB。正确做法：控制文件在就再跑一次 --continue 补缺片。
          if [ -f "${part}.aria2" ] && [ "$A2_RETRY" -lt 3 ]; then
            A2_RETRY=$((A2_RETRY + 1))
            log "aria2c 中止但控制文件在 ($got/$expected) → 第 $A2_RETRY/3 次续传，不丢分片"
            sleep 5; continue
          fi
          log "aria2c 未完整 ($got/$expected)，丢弃分片、转 curl…"
          # 🔴 aria2 用 -x16 **分段写**，文件大小 = 已写入的最高偏移，中间可能全是空洞。
          #    curl --continue-at - 只认"文件当前大小" → 从末尾续 → 下载 0 字节 →
          #    字节数判据通过 → 装上一个几乎全空的文件。没有控制文件就无从得知真实
          #    已下载区间，唯一安全做法是重下。
          rm -f "${part}.aria2" "$part"
          part_got=0
        fi
        break
      done

      # ── curl 回落（也是 aria2 不可用时的主路径）──
      part_got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
      log "curl 直连 $f (第 $attempt/$max 次，续传 $part_got/$expected) <- ${url##*/}"
      # 重试放在 curl 外面：每次尝试前重读 .partial 当前大小。curl 自己的 --retry
      # 会在瞬时断连后复用**过期的 -C 偏移**，把重叠的尾巴又追加一遍。
      if timeout 1800 curl --fail --location --continue-at - \
          --connect-timeout 30 --speed-time 120 --speed-limit 1048576 \
          --progress-bar --output "$part" "$url" 2>&1 | tail -3 | tee -a "$LOG"; then
        got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$got" = "$expected" ]; then
          mv "$part" "$dest"; log "✓ $f ($got B, curl)"; return 0
        fi
      fi
      got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
      # 这个镜像没成 → 换下一个镜像前**清掉 .partial**：不同镜像可能是不同的文件
      # （LoRA 那几个落盘名相同但来源仓库不同），续传会把两份内容拼在一起。
      log "✗ 镜像未成 ($got/$expected): ${url}"
      rm -f "$part" "${part}.aria2"
    done
    log "✗ $f 所有镜像都未成，${delay}s 后重试第 $((attempt+1))/$max 轮…"
    sleep $delay; delay=$((delay * 2)); attempt=$((attempt + 1))
  done
  log "[ERROR] 放弃: $f（$max 轮 × $(echo "$urls" | wc -w) 个镜像都未达到精确字节数）"
  return 1
}

main() {
  log "===== Eros Max provisioning 开始 ====="
  [ -f /venv/main/bin/activate ] && . /venv/main/bin/activate

  # ── 1) ComfyUI 版本 ──────────────────────────────────────────────────
  # v0.30.0 起才有 H3 原生节点 nodes_minimax_h3.py。这里对齐 rent 脚本的 COMFY_VERSION。
  log "校正 ComfyUI -> $COMFY_VERSION"
  if cd "$CU" 2>/dev/null; then
    git fetch --tags --force 2>&1 | tail -1 | tee -a "$LOG" || true
    git checkout "$COMFY_VERSION" 2>&1 | tail -1 | tee -a "$LOG" || true
    /venv/main/bin/pip install -q -r requirements.txt 2>&1 | tail -2 | tee -a "$LOG" || true
    if [ -f "$CU/comfy_extras/nodes_minimax_h3.py" ]; then
      log "✓ H3 原生节点存在（ComfyUI $(git describe --tags 2>/dev/null || echo '?')）"
    else
      log "[ERROR] H3 原生节点缺失（checkout $COMFY_VERSION 失败？）——工作流会报 node 缺失"
    fi
  else
    log "[ERROR] 进不去 $CU —— 镜像布局与预期不符，模型仍会下但 ComfyUI 版本未校正"
  fi
  # 注：本工作流 **0 个自定义节点包**（只用核心 LoraLoaderModelOnly），
  #     所以这里没有 h3-provision.sh 的 prefetch_nodes 并行段。

  # ── 2) 下模型 ────────────────────────────────────────────────────────
  mkdir -p "$MODELS"
  # flock 防多个安装器同时写同一个 .partial（租机脚本的 ensure_dits 用的是同一把锁）
  exec 9>"$MODELS/.h3-download.lock"
  log "等待模型下载锁…"
  if ! flock -w "${H3_DOWNLOAD_LOCK_TIMEOUT:-2700}" 9; then
    log "[ERROR] 等待下载锁超时"; return 1
  fi
  log "已取得下载锁"

  local total=0 spec f bytes urls
  for spec in "${SPECS[@]}"; do
    bytes="$(echo "$spec" | cut -d'|' -f2)"
    total=$((total + bytes))
  done
  log "共 ${#SPECS[@]} 个文件，合计 $((total / 1000000000)) GB（十进制）"

  # 串行下载：单文件 aria2 -x16 已吃满链路 81%，再叠并发只是多开连接、
  # 徒增被 CDN 限流的面（aria2 对 429 不重试，aria2#1421/#2295 至今 open）。
  local failed=0
  for spec in "${SPECS[@]}"; do
    f="${spec%%|*}"
    bytes="$(echo "$spec" | cut -d'|' -f2)"
    urls="$(echo "$spec" | cut -d'|' -f3)"
    download_one "$f" "$bytes" "$urls" || failed=$((failed + 1))
  done
  flock -u 9 || true

  # ── 3) 重启 comfyui 刷新 UNETLoader / LoraLoader 下拉列表 ─────────────
  supervisorctl restart comfyui 2>&1 | tail -1 | tee -a "$LOG" || true

  # ── 4) 校验 ─────────────────────────────────────────────────────────
  local ok=1 got
  for spec in "${SPECS[@]}"; do
    f="${spec%%|*}"
    bytes="$(echo "$spec" | cut -d'|' -f2)"
    got="$(stat -c %s "$MODELS/$f" 2>/dev/null || echo missing)"
    if file_complete "$f" "$bytes"; then log "OK  $f ($got B)"
    else log "[ERROR] 缺失/不完整 $f ($got/$bytes)"; ok=0; fi
  done

  if [ "$failed" -gt 0 ] || [ "$ok" -ne 1 ]; then
    log "[ERROR] 有模型没下成，provisioning 视为失败"
    return 1
  fi
  log "===== ✓ Eros Max provisioning 完成，模型齐全 ====="
}

main
