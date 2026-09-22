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
#       zs05_pruned_bf16(40G) / zs05_pruned_int8_convrot(21G)      <- joeygambino/MiniMax-H3-x-Z-Image-native
#       FeiHou_MiniMax-H3_Remix_v0.6(66G) / _int8_convrot_v2(34G)  <- FX-FeiHou/MiniMax-H3-Remix
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
    # ── 非 Comfy-Org 仓库的 DiT（见 h3_repo_for / h3_remote_path_for）──
    # 字节数取自各自仓库的 HF API + Range 请求实测（2026-09-03），逐位核对过。
    # zs05_bf16 与官方 pruned_bf16 **字节数完全相同**，只能靠文件名区分，别合并这两行。
    diffusion_models/minimax_h3_ref2va_pruned_zs05_bf16.safetensors)           echo 40225724176 ;;
    diffusion_models/minimax_h3_ref2va_pruned_zs05_int8_convrot.safetensors)   echo 20970379680 ;;
    diffusion_models/FeiHou_MiniMax-H3_Remix_v0.6.safetensors)                 echo 66246042528 ;;
    diffusion_models/FeiHou_MiniMax-H3_Remix_v0.6_int8_convrot_v2.safetensors) echo 34004449966 ;;
    text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors)              echo 51506295256 ;;
    vae/minimax_h3_video_vae_fp16.safetensors)                           echo 5207808496 ;;
    vae/minimax_h3_audio_vae_fp32.safetensors)                           echo 605254808 ;;
    *) return 1 ;;
  esac
}

# 🔴 2026-09-03：DiT 不再全在 Comfy-Org。本地一律落在 diffusion_models/ 下，
#    但 zs05 和 Remix 在各自仓库的**根目录**，所以仓库和仓库内路径要分开查。
#    不加这两个函数的话 url 会被拼成 Comfy-Org/.../diffusion_models/<外部文件名> -> 404，
#    provisioning 判失败、rent 脚本 raise RuntimeError 中止，
#    连后面那步知道正确仓库的 ensure_dits 都轮不到跑。
h3_repo_for() {
  case "$1" in
    diffusion_models/minimax_h3_ref2va_pruned_zs05_*.safetensors) echo "joeygambino/MiniMax-H3-x-Z-Image-native" ;;
    diffusion_models/FeiHou_MiniMax-H3_Remix_*.safetensors)       echo "FX-FeiHou/MiniMax-H3-Remix" ;;
    *) echo "$HF_REPO" ;;
  esac
}

h3_remote_path_for() {
  case "$1" in
    diffusion_models/minimax_h3_ref2va_pruned_zs05_*.safetensors) echo "${1##*/}" ;;
    diffusion_models/FeiHou_MiniMax-H3_Remix_*.safetensors)       echo "${1##*/}" ;;
    *) echo "$1" ;;
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
  [ -f "$MODELS/$f.turbo" ] && return 1          # turbo 分块下载的工作文件还在（没下完）
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
#   turbo  ← 默认（2026-09-15 起）。高并发短连接分块直下 HF，断点续传（见 h3_turbo 注释）。
#          ①两台宿主实测 aria2 会慢性失速（6 MiB/s、39–84 MiB/s），turbo 拉到 100–116、101–145 MiB/s（后者到线顶）
#   aria2  多连接 -x16。①级实测 481/479 MB/s = 链路 81%，n=2 复现；但部分宿主上跑久了会衰减（见 turbo）
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
H3_DOWNLOADER="${H3_DOWNLOADER:-turbo}"
case "$H3_DOWNLOADER" in turbo|aria2|curl|hf|hfxet) ;; *)
  log "[WARN] 未知 H3_DOWNLOADER=$H3_DOWNLOADER，回落 turbo"; H3_DOWNLOADER=turbo ;; esac

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
  local repo rpath
  repo="$(h3_repo_for "$f")"
  rpath="$(h3_remote_path_for "$f")"
  local url="https://huggingface.co/${repo}/resolve/main/${rpath}"
  [ "$repo" = "$HF_REPO" ] || log "外部仓库: $f <- $repo/$rpath"

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
    # 🔴 仓库内路径与本地路径不一致时**不能走 hf CLI**：`hf download REPO <根目录文件>
    #    --local-dir $MODELS` 会落到 $MODELS/<文件名>，而不是 $MODELS/diffusion_models/<文件名>，
    #    后面 h3_file_complete 按本地路径查会判"没下成"。这种文件直接走下面的 aria2/curl —
    #    它们用 --out / --output 显式指定落位，不受仓库结构影响。
    if { [ "$H3_DOWNLOADER" = "hf" ] || [ "$H3_DOWNLOADER" = "hfxet" ]; } && [ "$rpath" = "$f" ]; then
      log "hf download $f (第 $attempt/$max 次，H3_DOWNLOADER=$H3_DOWNLOADER，Xet=$([ "$H3_DOWNLOADER" = hfxet ] && echo 开 || echo 关))..."
      timeout 3600 "$HF_BIN" download "$repo" "$rpath" --local-dir "$MODELS" 2>&1 \
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

# ══ turbo 下载器（H3_DOWNLOADER=turbo，2026-09-15 起默认）═══════════════════════════
# ① 依据（两台宿主同机实测，事后 DiT/TE 都对上 HF 官方 sha256）：
#   · 50977105（Tulsa）：aria2 -x16 开局 110 MiB/s，10 分钟后掉到 6 MiB/s —— 长连接越跑越慢，
#     被 --lowest-speed-limit 踢掉的连接 aria2 不补；96 并发 × 64MiB 分块、每块一条新连接 → 100–116 MiB/s。
#   · 51087016（Virginia，登记 1.1 Gbps）：aria2 在 39–84 MiB/s 之间晃 → 128 并发 101–145 MiB/s（到线顶）。
# 做法：所有缺的文件交错派块同时下；每块 `curl -r` 一段，字节数精确才 pwrite 回工作文件并记进 sidecar；
#   全部块到齐才改名成正式文件名（h3_file_complete 仍只认"正式名 + 精确字节数 + 无残留"）。
#   工作文件：aria2 留下的 .partial + .partial.aria2 直接接着用（解析位图，SEEK_DATA 核对盘上真有数据）；
#   否则新建 <文件>.turbo。被打断（含 provisioner 杀掉重跑）下次从 sidecar 续传。
#   没有控制文件的 .partial、正式名上的半截文件都不知道哪些字节有效 → 删掉重下（也免得新旧两份一起占盘）。
#   600 秒没有任何进度就停下返回 1，由 main 再跑一遍续传。仓库 / 仓库内路径走 h3_repo_for / h3_remote_path_for。
# 调参：并发默认 64 起步自适应（-e H3_TURBO_START / -e H3_TURBO_MAX 384，上限还受可用内存约束）；
#   -e H3_TURBO_WORKERS=N 则固定 N 不自适应；-e H3_TURBO_CHUNK_MB（默认 64）。回老路径：-e H3_DOWNLOADER=aria2。
h3_turbo() {
  local f sz args=()
  for f in "$@"; do
    sz="$(h3_expected_bytes "$f")" || { log "[WARN] turbo 跳过未登记字节数的文件: $f"; continue; }
    args+=("$f|$(h3_repo_for "$f")|$(h3_remote_path_for "$f")|$sz")
  done
  [ ${#args[@]} -gt 0 ] || return 0
  "$(command -v python3 || echo /venv/main/bin/python)" - "$MODELS" "${args[@]}" <<'PY' 2>&1 | stdbuf -oL tee -a "$LOG"
import os, sys, json, time, struct, signal, threading, subprocess
from concurrent.futures import ThreadPoolExecutor

M = sys.argv[1]
JOBS = [a.split("|") for a in sys.argv[2:]]           # 本地相对路径|仓库|仓库内路径|字节数
TOKEN = os.environ.get("HF_TOKEN", "")
CHUNK = max(1, int(os.environ.get("H3_TURBO_CHUNK_MB") or 64)) << 20
# 并发自适应（2026-09-16）：固定并发换台机器就不对——
#   · 51177257（韩国，登记 482 Mbps）：单连接 <1 MiB/s，要 128 路才到 53 MiB/s（链路 90%）；
#   · huggingface_hub#4893（2026-09-13，①n=1）：25 Gbit 机器并发冲到 64 路，30 秒内从 2.3 GB/s 崩到 <1 MB/s，
#     锁到 4 路反而稳稳跑完 90 GB —— 并发不是越多越好。
#   做法：START 起步，每 WIN 秒看一次窗口吞吐，涨过 8% 就加一档；不涨就退回最好的那档并停止加档；
#         之后掉到最好值的 60% 以下就砍半重新试探。给 H3_TURBO_WORKERS 则固定该值、不自适应。
W_FIX = int(os.environ.get("H3_TURBO_WORKERS") or 0)
W_START = max(1, int(os.environ.get("H3_TURBO_START") or 64))
STEP, WIN = 64, 15
STALL_S = 600
STOP, DONE = threading.Event(), threading.Event()
G = threading.Lock()
STATS = {"written": 0, "err": 0, "active": 0, "last_t": time.time()}
FIN = []


def _mem_cap():
    """并发上限也受内存约束：每个在下的块要在内存里留一份（curl 输出）。"""
    try:
        for ln in open("/proc/meminfo"):
            if ln.startswith("MemAvailable:"):
                return max(32, int(int(ln.split()[1]) * 1024 * 0.25 // CHUNK))
    except Exception:
        pass
    return 128


W_MAX = W_FIX or min(int(os.environ.get("H3_TURBO_MAX") or 384), _mem_cap())


class Gate:
    """可以在运行中调容量的闸门（信号量改不了容量）。"""

    def __init__(self, n):
        self.cv = threading.Condition()
        self.limit, self.busy = n, 0

    def set(self, n):
        with self.cv:
            if n != self.limit:
                self.limit = n
                self.cv.notify_all()

    def acquire(self):
        with self.cv:
            while self.busy >= self.limit and not STOP.is_set():
                self.cv.wait(0.5)
            self.busy += 1

    def release(self):
        with self.cv:
            self.busy -= 1
            self.cv.notify()


GATE = Gate(W_FIX or W_START)


def say(msg):
    print(time.strftime("[%Y-%m-%d %H:%M:%S] turbo: ") + msg, flush=True)


def rm(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def nic_rx():
    """网卡累计收字节。调档必须按这个算窗口吞吐——按"窗口内下完的整块"算，
    刚加并发时大量块还在途中没完成，读数会假低，会把正确的档位误判成更慢（2026-09-22 在 52012206 上真踩到）。"""
    tot = 0
    try:
        for ln in open("/proc/net/dev"):
            if ":" not in ln:
                continue
            name, rest = ln.split(":", 1)
            if name.strip().startswith(("eth", "ens", "enp", "eno")):
                tot += int(rest.split()[0])
    except Exception:
        return 0
    return tot


def parse_aria2(path, size):
    # aria2 控制文件 v1（大端）：VER2 EXT4 IHLEN4 IH PLEN4 TOTAL8 UPLOAD8 BFLEN4 BITFIELD（位 MSB 先）
    b = open(path, "rb").read()
    if struct.unpack(">H", b[0:2])[0] != 1:
        raise ValueError("aria2 控制文件版本不支持: " + path)
    p = 6
    p += 4 + struct.unpack(">I", b[p:p + 4])[0]
    plen = struct.unpack(">I", b[p:p + 4])[0]
    p += 4
    total = struct.unpack(">Q", b[p:p + 8])[0]
    p += 16
    bfl = struct.unpack(">I", b[p:p + 4])[0]
    p += 4
    bf = b[p:p + bfl]
    n = (size + plen - 1) // plen
    if total != size or bfl != (n + 7) // 8 or len(bf) != bfl:
        raise ValueError("aria2 控制文件与期望大小不符: " + path)
    return plen, bytearray(1 if bf[i >> 3] & (0x80 >> (i & 7)) else 0 for i in range(n))


def data_extents(fd, limit):
    ext, off = [], 0
    while off < limit:
        try:
            d = os.lseek(fd, off, os.SEEK_DATA)
        except OSError:
            break
        if d >= limit:
            break
        try:
            h = min(os.lseek(fd, d, os.SEEK_HOLE), limit)
        except OSError:
            h = limit
        ext.append((d, h))
        off = h
    return ext


class Plan:
    def __init__(self, rel, repo, rpath, size):
        self.rel, self.repo, self.rpath, self.size = rel, repo, rpath, int(size)
        size = self.size
        self.final = fin = os.path.join(M, rel)
        part = fin + ".partial"
        os.makedirs(os.path.dirname(fin), exist_ok=True)
        if os.path.exists(fin):                     # bash 只交进来不完整的文件：正式名上的一定是半截
            if os.path.exists(fin + ".aria2"):      # aria2 直写正式名被打断 → 降级成 .partial 接着用（同 download_one）
                rm(part)
                rm(part + ".aria2")
                os.replace(fin, part)
                os.replace(fin + ".aria2", part + ".aria2")
            else:
                rm(fin)
        if os.path.exists(part) and os.path.exists(part + ".aria2"):
            self.work, src = part, "接管 aria2 分片"
        else:
            rm(part)
            self.work, src = fin + ".turbo", "新下"
        self.side = self.work + ".json"
        self.fd = os.open(self.work, os.O_RDWR | os.O_CREAT, 0o644)
        cur = os.fstat(self.fd).st_size
        if cur > size:
            os.ftruncate(self.fd, 0)
            rm(self.side)
            cur = 0
        if cur < size:
            os.ftruncate(self.fd, size)
        if os.path.exists(self.side):
            st = json.load(open(self.side))
            self.plen, self.done = st["plen"], bytearray(bytes.fromhex(st["done"]))
            src = "续传"
        elif self.work == part:
            self.plen, self.done = parse_aria2(part + ".aria2", size)
        else:
            self.plen = 1 << 20
            self.done = bytearray((size + self.plen - 1) // self.plen)
        # 记成已完成的分片，盘上必须真有数据（不是空洞），否则改判未完成
        ext, j = data_extents(self.fd, size), 0
        for i in range(len(self.done)):
            if not self.done[i]:
                continue
            s, e = i * self.plen, min((i + 1) * self.plen, size)
            while j < len(ext) and ext[j][1] <= s:
                j += 1
            if not (j < len(ext) and ext[j][0] <= s and ext[j][1] >= e):
                self.done[i] = 0
        per = max(1, CHUNK // self.plen)
        self.chunks, i, n = [], 0, len(self.done)
        while i < n:
            if self.done[i]:
                i += 1
                continue
            j = i
            while j < n and not self.done[j] and j - i < per:
                j += 1
            self.chunks.append((i, j))
            i = j
        self.left = len(self.chunks)
        self.missing = sum(min(b * self.plen, size) - a * self.plen for a, b in self.chunks)
        self.state = "downloading" if self.left else "complete"
        self.url_v, self.url_t, self.url_lock = None, 0.0, threading.Lock()
        self.dirty = False
        say("%s %s：还要下 %.2f GiB（%d 块）%s" % (rel, src, self.missing / 2**30, self.left,
                                             "" if rpath == rel else "（来自 %s/%s）" % (repo, rpath)))

    def url(self, force=False):
        with self.url_lock:
            if force or not self.url_v or time.time() - self.url_t > 900:
                cmd = ["curl", "-sS", "-o", "/dev/null", "--max-time", "30", "-w", "%{redirect_url}"]
                if TOKEN:
                    cmd += ["-H", "Authorization: Bearer " + TOKEN]
                cmd.append("https://huggingface.co/%s/resolve/main/%s" % (self.repo, self.rpath))
                r = subprocess.run(cmd, capture_output=True, text=True)
                u = r.stdout.strip()
                if u.startswith("https://"):
                    self.url_v, self.url_t = u, time.time()
                else:
                    say("resolve 失败 %s rc=%s %s" % (self.rel, r.returncode, r.stderr.strip()[:120]))
            return self.url_v

    def save(self):
        tmp = self.side + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"plen": self.plen, "done": bytes(self.done).hex()}, f)
        os.replace(tmp, self.side)


def finalize(p):
    with G:
        ok = all(p.done)
        p.state = "finalizing"
    if not ok:
        p.state = "incomplete"
        return
    try:
        os.fsync(p.fd)
        if os.fstat(p.fd).st_size != p.size:
            raise ValueError("工作文件大小 %d != %d" % (os.fstat(p.fd).st_size, p.size))
        os.close(p.fd)
        os.replace(p.work, p.final)
        for x in (p.side, p.side + ".tmp", p.final + ".partial", p.final + ".partial.aria2",
                  p.final + ".aria2", p.final + ".turbo"):
            rm(x)
        p.state = "placed"
        say("✓ %s（%d B）" % (p.rel, p.size))
    except Exception as ex:
        p.state = "error"
        say("🔴 %s 改名就位失败：%r" % (p.rel, ex))


def work(p, a, b):
    if STOP.is_set():
        return
    GATE.acquire()
    s, e = a * p.plen, min(b * p.plen, p.size)
    need = e - s
    with G:
        STATS["active"] += 1
    try:
        for att in range(1, 13):
            if STOP.is_set():
                return
            u = p.url(force=(att > 1 and att % 2 == 0))
            if not u:
                time.sleep(min(2 * att, 15))
                continue
            r = subprocess.run(["curl", "-sS", "--fail", "--http1.1", "--connect-timeout", "10",
                                "--max-time", "300", "--speed-limit", "262144", "--speed-time", "30",
                                "--max-filesize", str(need + 1), "-r", "%d-%d" % (s, e - 1), u],
                               capture_output=True)
            if r.returncode == 0 and len(r.stdout) == need:
                os.pwrite(p.fd, r.stdout, s)
                with G:
                    for i in range(a, b):
                        p.done[i] = 1
                    p.left -= 1
                    p.dirty = True
                    STATS["written"] += need
                    STATS["last_t"] = time.time()
                    last = p.left == 0
                if last:
                    t = threading.Thread(target=finalize, args=(p,))
                    t.start()
                    FIN.append(t)
                return
            with G:
                STATS["err"] += 1
            time.sleep(min(1.5 * att, 15))
    finally:
        with G:
            STATS["active"] -= 1
        GATE.release()


def monitor(plans, total):
    t_print, w_print = time.time(), 0
    rx_print = nic_rx()
    settle = 0
    best_rate, best_w, ramping = 0.0, GATE.limit, W_FIX == 0
    while not DONE.wait(5):
        with G:
            dirty = [p for p in plans if p.dirty and p.state == "downloading"]
            for p in dirty:
                p.dirty = False
            w, active, err, last_t = STATS["written"], STATS["active"], STATS["err"], STATS["last_t"]
        for p in dirty:
            try:
                p.save()
            except Exception as ex:
                say("sidecar 写失败 %r" % ex)
        now = time.time()
        if now - t_print >= WIN:
            rx = nic_rx()
            rate_chunk = (w - w_print) / (now - t_print)
            rate = (rx - rx_print) / (now - t_print) if rx and rx_print and rx > rx_print else rate_chunk
            rx_print = rx
            eta = "%dm%02ds" % divmod(int((total - w) / rate), 60) if rate > 0 else "--"
            print("[#turbo %.1fGiB/%.1fGiB(%d%%) CN:%d/%d 网卡:%dMiB ETA:%s 重试:%d]"
                  % (w / 2**30, total / 2**30, 100 * w // max(total, 1), active, GATE.limit,
                     rate / 2**20, eta, err), flush=True)
            t_print, w_print = now, w
            if settle > 0:                     # 刚改过档，这一窗只记不判（在途的块还没算进来）
                settle -= 1
                if rate > best_rate:
                    best_rate, best_w = rate, GATE.limit
            elif ramping and rate > 0:
                tried = GATE.limit
                if rate > best_rate * 1.08:
                    best_rate, best_w = rate, tried
                    if tried < W_MAX:
                        GATE.set(min(W_MAX, tried + STEP))
                        settle = 1
                        say("并发 %d→%d（这一档 %d MiB/s，还在涨）" % (tried, GATE.limit, rate / 2**20))
                    else:
                        ramping = False
                        say("并发已到上限 %d（%d MiB/s）" % (tried, rate / 2**20))
                else:
                    ramping = False
                    GATE.set(best_w)
                    say("并发定在 %d（加到 %d 只有 %d MiB/s，没超过 %d MiB/s）"
                        % (best_w, tried, rate / 2**20, best_rate / 2**20))
            elif not ramping and best_rate > 0 and rate > 0 and rate < best_rate * 0.6 and GATE.limit > 16:
                say("吞吐掉到 %d MiB/s（曾 %d），并发 %d→%d 重新试探"
                    % (rate / 2**20, best_rate / 2**20, GATE.limit, max(16, GATE.limit // 2)))
                GATE.set(max(16, GATE.limit // 2))
                best_rate, ramping, settle = rate, True, 1
        if now - last_t > STALL_S and not STOP.is_set():
            say("🔴 %d 秒没有任何进度，停下（已下的分片记在 sidecar，下一遍续传）" % STALL_S)
            STOP.set()


def main():
    try:
        plans = [Plan(*j) for j in JOBS]
    except Exception as ex:
        say("🔴 准备工作文件失败：%r" % ex)
        return 2
    total = sum(p.missing for p in plans)
    say("%d 个文件，这次要下 %.1f GiB；块 %d MiB；并发 %s"
        % (len(plans), total / 2**30, CHUNK >> 20,
           ("固定 %d（H3_TURBO_WORKERS）" % W_FIX) if W_FIX else ("%d 起步、上限 %d、自适应" % (W_START, W_MAX))))
    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    threading.Thread(target=monitor, args=(plans, total), daemon=True).start()
    for p in plans:
        if p.state == "complete":
            t = threading.Thread(target=finalize, args=(p,))
            t.start()
            FIN.append(t)
    with ThreadPoolExecutor(max_workers=max(W_MAX, GATE.limit)) as ex:
        queues = [list(p.chunks) for p in plans]      # 交错派块：几个文件同时推进，小 VAE 很快就位
        while any(queues):
            for p, q in zip(plans, queues):
                if q:
                    ex.submit(work, p, *q.pop(0))
    for t in list(FIN):
        t.join()
    DONE.set()
    for p in plans:
        if p.state == "downloading":
            p.state = "incomplete"
            try:
                p.save()
            except Exception:
                pass
    bad = ["%s=%s" % (p.rel, p.state) for p in plans if p.state != "placed"]
    say("本遍结束：" + ("全部就位" if not bad else "未完成 " + ", ".join(bad)))
    return 0 if not bad else 1


sys.exit(main())
PY
  return "${PIPESTATUS[0]}"
}


# ══ 节点包预取：与模型下载并行 ═══════════════════════════════════════════
# 🔴 为什么加这个（2026-09-04）：
#    原来租机脚本是**等模型下完**再通过 SSH 一个个推安装脚本装节点包，
#    单次 SSH 往返约 3.7s（见 rent_5090_prod.py 的 _ssh_put_run 注释），8 个包全串在
#    下载之后。而这些包全是几 MB 的 git clone，和上百 GB 的模型下载根本不抢资源 ——
#    在这里后台起一份，整个串行段几乎消失。
#
# ⚠️ 三条纪律，别改：
#   1. **必须在 ComfyUI 自己的 `pip install -r requirements.txt` 之后启动。**
#      同一个 venv 并发 pip 会损坏 site-packages —— 这不是理论风险，rent 脚本里
#      早就写着"同 venv 并发 pip 会损坏"。所以本函数的启动点在那一行下面，不能上移。
#   2. **这里只负责「拿到」，不负责「判对」。** 租机脚本里的 ensure_* 一个都不删：
#      它们仍逐个校验字节/目录、缺了补、还负责钉版本。本函数失败一律 `|| true`，
#      最坏就是退回原来的串行装法，绝不让 provisioning 失败。
#   3. **DLSS5 那套（Proton/vkd3d/dxvk-nvapi/Merserk 运行时）不在这里。**
#      那是 --dlss5 才装的可选项，动辄 1 GB，不该占开机路径。
#
# 结果写 $PREFETCH_MANIFEST，租机脚本可以据此知道预取干了什么（现在只作日志用）。
PREFETCH_MANIFEST="${WORKSPACE_DIR}/.h3_node_prefetch"
PREFETCH_LOG="${WORKSPACE_DIR}/.h3_node_prefetch.log"

prefetch_nodes() {
  local cn="$CU/custom_nodes"
  mkdir -p "$cn" || return 0
  : > "$PREFETCH_MANIFEST"; : > "$PREFETCH_LOG"
  cd "$cn" || return 0

  # 仓库|目录名|分支(空=默认)|要不要装 requirements
  local specs=(
    "https://github.com/kijai/ComfyUI-KJNodes|ComfyUI-KJNodes||1"
    "https://github.com/SeanScripts/ComfyUI-Unload-Model|ComfyUI-Unload-Model||0"
    "https://github.com/starsFriday/ComfyUI-MiniMax-H3-LegacySampling|ComfyUI-MiniMax-H3-LegacySampling||0"
    "https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3|ComfyUI-Spectrum-MiniMax-H3||0"
    "https://github.com/kijai/ComfyUI-SolAttn_triton|ComfyUI-SolAttn_triton||0"
    "https://github.com/Saganaki22/ComfyUI-sol-attn|ComfyUI-sol-attn||0"
    "https://github.com/Jalen-Brunson/ComfyUI-MiniMax-H3-PDD-Acc|ComfyUI-MiniMax-H3-PDD-Acc||0"
    "https://github.com/DonutsDelivery/ComfyUI-DonutNodes|ComfyUI-DonutNodes|feat/linux-dlss5-experimental|1"
    # ↓ Remix 机专用（rent_5090_remix.py 的 REMIX_PACKS）。两种机器共用本开机脚本，
    #   多取这 3 个各几 MB 的包对 H3 机没有代价；用不到的包不接线就不生效。
    #   want_req=1 是照 remix 的 ensure_node_pack 口径 —— 它会装 requirements.txt。
    "https://github.com/FX-FeiHou/ComfyUI-FeiHou-Easy-H3|ComfyUI-FeiHou-Easy-H3||1"
    "https://github.com/FX-FeiHou/ComfyUI-FeiHou-Toolbox|ComfyUI-FeiHou-Toolbox||1"
    "https://github.com/rgthree/rgthree-comfy|rgthree-comfy||1"
  )

  local n_have=0 n_get=0 n_fail=0
  for spec in "${specs[@]}"; do
    IFS='|' read -r url dir branch want_req <<<"$spec"
    if [ -d "$dir/.git" ]; then
      echo "HAVE $dir" >> "$PREFETCH_MANIFEST"; n_have=$((n_have+1)); continue
    fi
    rm -rf "$dir"
    if [ -n "$branch" ]; then
      timeout 240 git clone --depth 1 -b "$branch" "$url" "$dir" >>"$PREFETCH_LOG" 2>&1
    else
      timeout 240 git clone --depth 1 "$url" "$dir" >>"$PREFETCH_LOG" 2>&1
    fi
    if [ -d "$dir/.git" ]; then
      echo "GET  $dir" >> "$PREFETCH_MANIFEST"; n_get=$((n_get+1))
    else
      # GitHub 对机房 IP 瞬时限流是已知现象（rent 脚本 preflight_net 的注释里有实例）。
      # 这里不重试、不阻塞——留给 ensure_* 去补，它有重试和 codeload 兜底。
      echo "FAIL $dir" >> "$PREFETCH_MANIFEST"; n_fail=$((n_fail+1)); continue
    fi
    # requirements 只给明确需要的两个装，且**串行**——不能并发 pip。
    if [ "$want_req" = "1" ] && [ -s "$dir/requirements.txt" ]; then
      local req="$dir/requirements.txt"
      # DonutNodes 的 requirements 里有 opencv-python-headless，会盖掉环境里已有的 cv2。
      # 已有 cv2 就把 opencv 那行剔掉再装（与 rent 脚本 ensure_donut_nodes 同一口径）。
      if /venv/main/bin/python -c "import cv2" >/dev/null 2>&1; then
        grep -viE '^opencv' "$dir/requirements.txt" > /tmp/_pf_req.txt 2>/dev/null && req=/tmp/_pf_req.txt
      fi
      timeout 600 /venv/main/bin/pip install -q -r "$req" >>"$PREFETCH_LOG" 2>&1 || \
        echo "REQFAIL $dir" >> "$PREFETCH_MANIFEST"
      rm -f /tmp/_pf_req.txt
    fi
  done
  log "节点包预取完成：已有 $n_have / 新取 $n_get / 失败 $n_fail（失败的交给租机脚本 ensure_* 补）"
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

  # 🔴 预取必须起在这一行**之后**：上面那句是 ComfyUI 自己的 pip，同 venv 并发 pip 会损坏。
  #    起在这里之后 = 与模型下载并行（下载才是长杆），与任何 pip 都不重叠。
  prefetch_nodes &
  PREFETCH_PID=$!
  log "节点包预取已在后台启动（pid $PREFETCH_PID），与模型下载并行"
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
  if [ ${#missing[@]} -gt 0 ] && [ "$H3_DOWNLOADER" = "turbo" ]; then
    # turbo：分块并发下完所有缺的文件；没下完的（块失败 / 600s 无进度）从 sidecar 续传，最多 3 遍。
    # 不交给 aria2 兜底：它会从 0 另起一份 .partial，和 turbo 的工作文件一起占双份盘。
    log "turbo → ${#missing[@]} 个文件分块并发下载（并发 ${H3_TURBO_WORKERS:-128} × 块 ${H3_TURBO_CHUNK_MB:-64}MiB）"
    local pass
    for pass in 1 2 3; do
      missing=()
      for f in "${H3_FILES[@]}"; do h3_file_complete "$f" || missing+=("$f"); done
      [ ${#missing[@]} -eq 0 ] && break
      [ "$pass" -gt 1 ] && log "turbo 第 $pass 遍：还差 ${#missing[@]} 个文件，从 sidecar 续传"
      h3_turbo "${missing[@]}" || true
    done
  elif [ ${#missing[@]} -gt 0 ] && [ "$H3_DOWNLOADER" != "aria2" ]; then
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
    if [ "$H3_DOWNLOADER" = "turbo" ]; then
      h3_file_complete "$f" && continue
      log "[ERROR] turbo 3 遍后仍不完整: $f（provisioner 重跑本脚本时从 sidecar 续传；换老路径用 -e H3_DOWNLOADER=aria2）"
      failed=$((failed+1))
    else
      h3_file_complete "$f" || download_one "$f" || failed=$((failed+1))
    fi
  done
  flock -u 9 || true

  # 3) 重启 comfyui 刷新 UNETLoader/CLIPLoader 列表（新下的模型才认得出）
  #    先收掉后台预取——自定义节点包只在 ComfyUI 启动时扫描，这一次重启要能把它们一起加载，
  #    否则租机脚本还得再重启一次。等它是安全的：prefetch_nodes 内部每步都有 timeout。
  if [ -n "${PREFETCH_PID:-}" ]; then
    wait "$PREFETCH_PID" 2>/dev/null || true
    [ -s "$PREFETCH_MANIFEST" ] && log "预取清单: $(tr '\n' ' ' < "$PREFETCH_MANIFEST")"
  fi
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
