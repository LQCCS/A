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

# 🔴 完整性判据 = 精确字节数 **且** 没有 aria2 控制文件 / .partial 兄弟文件。
#    **只看字节数会被 prealloc 骗过** —— 本文件 188 行附近的注释早就记下了
#    "aria2 预分配整个文件、du 从第一秒就是满的"，但当时没把这个事实接到判据上。
#    2026-08-21 实测代价（实例 48277679）：一个被打断的 aria2 下载留下的文件
#    `stat -c %s` = 66280487368（与期望值一字节不差），只有 80% 真数据；
#    ComfyUI 照常加载 → 采样出 NaN → SaveVideo 报
#    `avcodec_send_frame() returned 22 ... [aac] Input contains (near) NaN/+-Inf`。
#    aria2 **只在成功完成时**自己删控制文件，所以它在 = 没下完。
h3_file_complete() {
  local f="$1"
  local expected got
  expected="$(h3_expected_bytes "$f")" || return 1
  [ -f "$MODELS/$f" ] || return 1
  [ -f "$MODELS/$f.aria2" ] && return 1          # 直接写最终名的未完成下载
  [ -f "$MODELS/$f.partial.aria2" ] && return 1  # 走 .partial 的未完成下载
  [ -f "$MODELS/$f.partial" ] && return 1        # 还有残留分片
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

# ══ 下载器选择：**由 -e H3_DOWNLOADER 传入，换档不用改本脚本、不用推 GitHub** ═══════
#   aria2  ← 默认。多连接 -x16。①级实测 481/479 MB/s = 链路 81%，n=2 复现
#   curl   单流直连（= aria2 原本的回落路径）。单独选它是为了做**对照臂**
#   hf     `hf download`，Xet 关。①实测 27 MB/s（4.5% 链路）
#          ⚠️ 这是 hf 的**最慢配置**：Xet 关 + huggingface_hub v1.x 已移除 hf_transfer
#             = 纯单流 HTTPS × workers。别拿它当"hf 天生慢 18×"的证据
#   hfxet  `hf download`，Xet 开。本机 2026-08-18 实测卡死 99.1%；
#          但 2026-08-24 复核，当初据以关掉它的三条 issue 全是 state_reason=completed：
#            · xet-core#789 HF 工程师"CDN configuration issues + quick patches"，报告者复测已好
#            · hub#3580     HF 关闭，但 2025-12-18 有人报同样症状 → **未必彻底**
#            · hub#4223     "fixed in hf_xet >= 1.5.1"（维护者本地复现并确认）
#          → 本机那次失败在三条修复**之后**：要么是新问题，要么当时 hf_xet 版本过旧
#          ⚠️ 就算完全正常也赢不了 aria2：aria2 已吃到链路 81%，天花板只剩 1.23×；
#             Xet 唯一理论优势是 chunk 去重，而**新租机本地无 chunk 可去重** → 收益恒为 0
#          留这个档只为一次性机器上实测，别拿它跑生产
H3_DOWNLOADER="${H3_DOWNLOADER:-aria2}"
case "$H3_DOWNLOADER" in aria2|curl|hf|hfxet) ;; *)
  log "[WARN] 未知 H3_DOWNLOADER=$H3_DOWNLOADER，回落 aria2"; H3_DOWNLOADER=aria2 ;; esac

# hf_transfer 在 huggingface_hub v1.0+ 已被**静默忽略**（Xet 取代），装了是空操作——
# 保留只为老版本镜像，别把它当成"加速已开启"的证据。hf_xet 只有 hfxet 档才真的用得上。
"$HF_DIR/pip" install -q -U hf_transfer hf_xet >/dev/null 2>&1 || pip install -q -U hf_transfer hf_xet >/dev/null 2>&1 || true
# aria2c 只在选了 aria2 档时才装（省掉一次 apt）。`|| true`：开机 apt 锁被占不该拖垮 provisioning。
if [ "$H3_DOWNLOADER" = "aria2" ]; then
  command -v aria2c >/dev/null 2>&1 || \
    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null 2>&1) || true
fi
_xetv="$("$HF_DIR/python" -c 'import hf_xet;print(hf_xet.__version__)' 2>/dev/null || echo none)"
log "下载器: H3_DOWNLOADER=$H3_DOWNLOADER（aria2c=$(command -v aria2c >/dev/null 2>&1 && echo 有 || echo 无)，hf_xet=$_xetv）"

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
# 🔴 2026-08-24：这段"关 Xet"现在**只对 aria2/curl/hf 三档生效**；选 hfxet 才放它出来。
#    上面三条 issue 已全部 completed（见 H3_DOWNLOADER 处），但本机 8/18 的失败在修复之后，
#    所以默认仍然关——**改档只需 -e H3_DOWNLOADER=hfxet，不用动这个脚本**。
if [ "$H3_DOWNLOADER" = "hfxet" ]; then
  unset HF_HUB_DISABLE_XET 2>/dev/null || true
  export HF_XET_HIGH_PERFORMANCE=1
  log "[WARN] H3_DOWNLOADER=hfxet：Xet 已启用。本机 2026-08-18 曾卡死 99.1%，只在一次性机器上用。"
else
  export HF_HUB_DISABLE_XET=1
  unset HF_XET_HIGH_PERFORMANCE HF_XET_NUM_CONCURRENT_RANGE_GETS 2>/dev/null || true
fi
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-300}"   # 大分片建议加长，见 hub#3580
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
  # A2_RETRY 用 local：aria2 续传计数必须**每个文件重置**（成功时 return 0 不会走到下面那处重置）
  local attempt=1 max=4 delay=4 A2_RETRY=0
  local url="https://huggingface.co/${HF_REPO}/resolve/main/${f}"

  expected="$(h3_expected_bytes "$f")" || {
    log "[ERROR] 未登记精确字节数: $f"; return 1;
  }
  if h3_file_complete "$f"; then log "已存在且字节数正确，跳过: $f"; return 0; fi
  mkdir -p "$(dirname "$dest")"

  # 🔴 最终文件旁若有 .aria2 控制文件 → 它是一次**直接写最终文件名**的未完成下载
  #    （手工跑 `aria2c -o <最终名>` 会造成这个）。此时 stat 拿到的是 prealloc 的满尺寸，
  #    会让下面的"字节数异常且不可续传"分支直接判死。先降级成 .partial 让它能续传/重下。
  if [ -f "${dest}.aria2" ]; then
    log "检测到最终文件旁有 aria2 控制文件（未完成的直写下载），降级为 .partial: $f"
    rm -f "$part" "${part}.aria2"
    mv -f "$dest" "$part" 2>/dev/null || true
    mv -f "${dest}.aria2" "${part}.aria2" 2>/dev/null || true
  fi

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
    # ── 优先 aria2c 多连接（-x16）──────────────────────────────────────────────
    # ⚠️ **依据等级：机制推理⑤ + 一条官方口径②，没有当前时间线的对照实测**（2026-08-20 核过时间线）：
    #   ✅ ② HF 员工 rajatarya（xet-core#592，2025-12，仍 open）原话：
    #      "There is **no reliable way to serve files larger than 50GB over a single HTTP connection**"
    #      → TE 51.5G / bf16 DiT 66.3G 正好压在这条线上面，多连接对**这两个文件**有官方口径支持。
    #   ⚠️ ④ 到处被转述的"官方 CLI 只用到 10~20% 带宽"= bughoho/hfdownloader 的 README 自测，
    #      那仓库 **2024-10-17 建、2024-10-18 停更、9 星**，测的是 **Xet 之前**的旧版 CLI。**别当实测引用。**
    #      同理它那句"千兆跑满 100MB/s"是靠**自建 Cloudflare Worker 反代多服务器**拿到的，**不是 aria2 -x16**。
    #   ⚠️ 反面也一样过期：padeoe/hfd gist 评论区有"aria2c 几乎下不动 / 末尾掉到<100k/s 卡住"的
    #      真实用户报告，但都在 **2024-03 ~ 2025-02**，而 HF 这两年换掉了整条传输栈
    #      （Xet 成默认、hub 1.0+ 移除 hf_transfer、2026-08 因攻击在 GCP 重建 CDN）。
    #      该 gist 评论 **2025-09 后归零**，2026 年一条都没有。
    #   → **正反证据全部产生于旧传输栈，都不作数。装它是因为"失败可回落、代价接近零"，不是因为已证明更快。**
    #      真实收益必须用同机 A/B（curl 单流 vs aria2 -x16 各 60s，交替两轮）来定。
    # ⚠️ 不装/不可用一律回落到下面的 curl（原路径原样保留，续传语义一致：都靠 .partial 的现有字节数）。
    #
    # ── hf / hfxet 档：交给 hf CLI 单文件下载 ─────────────────────────────────────
    # 🔴 完整性判据仍然只认**精确字节数**，不认退出码——hub#4223 的原话就是
    #    "exits 0 while leaving .incomplete blobs"。hf 把半成品写在自己的 cache 里
    #    （不是 $f.partial 的兄弟位置），所以 h3_file_complete 的兄弟文件检查覆盖不到它，
    #    这里额外扫一次 cache 目录。失败一律回落 curl，续传语义不受影响。
    if [ "$H3_DOWNLOADER" = "hf" ] || [ "$H3_DOWNLOADER" = "hfxet" ]; then
      log "hf download $f (第 $attempt/$max 次，H3_DOWNLOADER=$H3_DOWNLOADER，Xet=$([ "$H3_DOWNLOADER" = hfxet ] && echo 开 || echo 关))..."
      timeout 3600 "$HF_BIN" download "$HF_REPO" "$f" --local-dir "$MODELS" 2>&1 \
        | stdbuf -oL tail -3 | stdbuf -oL tee -a "$LOG" || true
      got="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
      _inc="$(find "$MODELS/.cache/huggingface/download" -name '*.incomplete' 2>/dev/null | head -1)"
      if [ "$got" = "$expected" ] && [ -z "$_inc" ]; then
        log "✓ $f ($got B, $H3_DOWNLOADER)"
        return 0
      fi
      [ -n "$_inc" ] && log "hf 退出但 cache 里仍有 .incomplete（hub#4223 症状）→ 判未完成"
      log "hf 未完整 ($got/$expected)，丢弃、转 curl 从 0 重下…"
      rm -f "$dest"; rm -rf "$MODELS/.cache/huggingface/download" 2>/dev/null || true
      part_got=0
    elif [ "$H3_DOWNLOADER" = "aria2" ] && command -v aria2c >/dev/null 2>&1; then
      log "aria2c 多连接下载 $f (第 $attempt/$max 次，-x16 续传 $part_got/$expected)..."
      # 🔴 `--summary-interval=20` 必须开（2026-08-20 踩，实例 48277770/48277679）：
      #    aria2 **预分配整个文件**（实测下载中的 .partial：apparent 51,506,295,256 =完整大小，
      #    blocks×512 = 51,506,302,976 也已全满）→ **`du -sb` 和 `du -sB1` 两个都从第一秒就是满的**，
      #    租机脚本那边基于 du 的进度条因此要么报"约剩 0 分钟"(假完成)、要么报"速率≈0 停滞"(假挂死)。
      #    → 唯一可信的进度来自 aria2 自己的 summary（`[#xxxx 12GiB/34GiB(35%) CN:16 DL:480MiB ETA:45s]`）。
      #    输出链路：`tr \r \n` 把它的回车刷新拆成行 → 只留 summary/结果行 → **stdbuf 行缓冲的 tee**
      #    同时写 $LOG 和 stdout；stdout 会被 vast 收进 /var/log/provisioning.log，
      #    租机脚本 `tail -n 8` 那一步就能实时看见。**别再在后面接 `| tail -N`**——那会等到 EOF 才吐字。
      # ⚠️ **不看管道退出码**：`grep` 没匹配到行会退出 1，配合 `set -o pipefail` 会把成功误判成失败。
      #    判据只用**精确字节数**（本来就比退出码强）。
      # 🔴 --file-allocation=none：别再让 aria2 预分配。开着 prealloc 时
      #    "文件大小"从第一秒就等于最终大小，进度、续传偏移、完整性判据全部失去意义。
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
      # 🔴 判据两条都要：字节数匹配 **且** 控制文件已被 aria2 自己删掉（= 真的下完了）。
      #    别把 `rm -f .aria2` 放到判断之前——那是先毁证据再判断。
      if [ "$got" = "$expected" ] && [ ! -f "${part}.aria2" ]; then
        mv "$part" "$dest"
        log "✓ $f ($got B, aria2c)"
        return 0
      fi
      # 🔴 aria2 没下完 → **.partial 必须丢弃，不能交给 curl 续传**。
      #    原注释说"留着控制文件会让 curl 的 -C - offset 对不上"——方向反了：
      #    真正的问题是 aria2 用 -x16 **分段写**，文件大小 = 已写入的最高偏移，
      #    中间可能全是空洞；叠加 prealloc 更是开局就满尺寸。
      #    curl --continue-at - 只认"文件当前大小" → 从末尾续 → 下载 0 字节 →
      #    下面的 `[ "$got" = "$expected" ]` 通过 → 装上一个几乎全空的文件。
      #    没有控制文件就无从得知真实已下载区间，唯一安全做法是重下。
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
      rm -f "${part}.aria2" "$part"
      part_got=0
    fi
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
  # ══ 🔴 有 aria2c 就全部走 aria2c，整个跳过 hf 批次（2026-08-20 同机实测定案）══════════
  # 实例 48189450（RTX PRO 6000 WS @ Czechia，链路 4771 Mbps = 596 MB/s）**同一台机、同一次装机**：
  #   · aria2c -x16 拉 TE 51,506,295,256 B：07:57:46 → 07:59:33 = 107s → **481 MB/s（81% 链路）**
  #     （数字取自本脚本自己的 log 时间戳 + 精确字节校验通过后才打的 ✓，不是 du 估的）
  #   · 同一次装机里 hf download --max-workers 4 拉剩下 3 个文件：**27 MB/s（4.5% 链路）**
  #   → **≈18×**。所以"只有 >50GB 才走 aria2"的阈值是反的，aria2c 在时 hf 批次没有存在价值。
  # ⚠️ n=1、两段不在同一时间窗、aria2 那 107s 还在和 hf 抢带宽（单独跑只会更高）。
  # 为什么**不**并发多个文件：单文件 -x16 已吃满 81% 链路，再叠并发只是多开连接、徒增被 CDN
  #   限流的面（aria2 对 429 不重试，见 aria2#1421/#2295 至今 open）。交给下面的串行兜底循环即可。
  # 2026-08-24：这个"跳过 hf 批次"的闸门现在也认 H3_DOWNLOADER —— 只要不是默认的 aria2 档，
  # 就一律交给下面的串行 download_one，由它按 H3_DOWNLOADER 分流（hf/hfxet/curl 各走各的）。
  if [ ${#missing[@]} -gt 0 ] && [ "$H3_DOWNLOADER" != "aria2" ]; then
    log "H3_DOWNLOADER=$H3_DOWNLOADER → ${#missing[@]} 个文件全部交给串行 download_one 按该档下载"
  elif [ ${#missing[@]} -gt 0 ] && command -v aria2c >/dev/null 2>&1; then
    log "aria2c 可用 → **${#missing[@]} 个文件全部走 aria2c -x16**（实测 481MB/s vs hf 27MB/s），跳过 hf 批次"
  elif [ ${#missing[@]} -gt 0 ]; then
    # 没有 aria2c 才退回"按大小分流"：>50GB 交给 hf 会让**整批**中断（见 HF_MAX_BYTES 处实测）
    for f in "${missing[@]}"; do
      sz="$(h3_expected_bytes "$f" 2>/dev/null || echo 0)"
      if [ "$sz" -gt "$HF_MAX_BYTES" ]; then big+=("$f"); else small+=("$f"); fi
    done
    if [ ${#big[@]} -gt 0 ]; then
      log "无 aria2c；超 $((HF_MAX_BYTES/1000000000))GB 的 ${#big[@]} 个走 curl 直连（hf 会拒）：${big[*]}"
      for f in "${big[@]}"; do download_one "$f" & pids+=("$!"); done
    fi
    if [ ${#small[@]} -gt 0 ] && "$HF_BIN" download --help 2>&1 | grep -q -- "--max-workers"; then
      log "无 aria2c；并行拉 ${#small[@]} 个 ≤$((HF_MAX_BYTES/1000000000))GB 文件（--max-workers ${H3_DL_WORKERS:-4}）"
      ( "$HF_BIN" download "$HF_REPO" "${small[@]}" --local-dir "$MODELS" \
          --max-workers "${H3_DL_WORKERS:-4}" 2>&1 | tail -4 | tee -a "$LOG" || \
          log "[WARN] hf 并行未全成，转逐个兜底" ) & pids+=("$!")
    elif [ ${#small[@]} -gt 0 ]; then
      log "hf CLI 无 --max-workers（旧版），这 ${#small[@]} 个交给下面逐个兜底"
    fi
  fi
  for p in "${pids[@]}"; do wait "$p" || true; done   # 两路都收完再进兜底校验
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
