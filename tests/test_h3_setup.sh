#!/bin/bash
# 回归：h3-setup.sh 的装机语义。全部用 PATH 打桩 + 小字节 fixture，不碰网络、不碰真机。
# 覆盖 6 件事：
#   1) 默认 DiT 是 bf16（改默认会在这里立刻暴露）
#   2) 模型下载走 .partial → 精确字节才原子落位，完成后不留 .partial
#   3) Spectrum 幂等：第一次 clone，重跑不再 clone
#   4) NO_SPECTRUM=1 / NO_SAGE=1 真的跳过
#   5) COMFYUI_ARGS 清洗：--highvram / --disable-dynamic-vram 都被剥掉，其余保留
#   6) ⚠️ DynamicVRAM 检查的三条分支：读不到命令行要报 "??"（**不能报 OK**，那是假通过）
set -uo pipefail

SOURCE_SCRIPT="${1:-}"
[ -n "$SOURCE_SCRIPT" ] && [ -f "$SOURCE_SCRIPT" ] || {
  echo "usage: test_h3_setup.sh /path/to/h3-setup.sh"; exit 1; }
SOURCE_SCRIPT="$(cd "$(dirname "$SOURCE_SCRIPT")" && pwd)/$(basename "$SOURCE_SCRIPT")"

PASSED=0
fail() { echo "FAIL: $*"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -40; exit 1; }
ok()   { echo "  ok · $*"; PASSED=$((PASSED+1)); }

# ─────────────────────────────────────────────────────────────────────────────
# 打桩
# ─────────────────────────────────────────────────────────────────────────────
make_stubs() {
  local R="$1"
  mkdir -p "$R/stub"

  # curl 身兼二职：① 下模型 ② 打 ComfyUI HTTP API。按 URL 分流。
  cat > "$R/stub/curl" <<'STUB'
#!/bin/bash
out=''; url=''; fail_flag=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) out="$2"; shift 2 ;;
    --fail) fail_flag=1; shift ;;
    -sf|-sL|-s) shift ;;
    --max-time|--connect-timeout|--speed-time|--speed-limit) shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */system_stats)                              echo '{"system":{}}'; exit 0 ;;
  */object_info/SpectrumApplyMiniMaxH3)
      # 只有真 clone 过才当作已注册（用标记文件模拟 ComfyUI 加载了该节点）
      if [ -f "$STUB_STATE/spectrum_loaded" ]; then
        echo '{"SpectrumApplyMiniMaxH3":{"input":{}}}'; exit 0
      fi
      echo '{}'; exit 0 ;;
esac
case "${url##*/}" in
  minimax_h3_ref2va_*.safetensors)          size=103 ;;
  qwen3vl_32b_minimax_h3_bf16.safetensors)  size=101 ;;
  minimax_h3_video_vae_fp16.safetensors)    size=102 ;;
  minimax_h3_audio_vae_fp32.safetensors)    size=100 ;;
  *) echo "unexpected URL: $url" >&2; exit 22 ;;
esac
[ -n "$out" ] || { echo 'missing curl output path' >&2; exit 2; }
mkdir -p "$(dirname "$out")"
got=$(stat -c '%s' "$out" 2>/dev/null || echo 0)
if [ "$got" -eq 0 ]; then          # 首次半截，逼出续传路径
  head -c "$((size / 2))" /dev/zero > "$out"
  echo 'stub-transient' >&2; exit 18
fi
head -c "$((size - got))" /dev/zero >> "$out"
echo "stub-206 ${url##*/} $size"
STUB

  # aria2c 存在但拒绝 → 确定性地逼出 curl 兜底（否则结果取决于宿主装没装 aria2）
  cat > "$R/stub/aria2c" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "aria2 version 1.stub"; exit 0; }
echo 'stub-aria2c-refuses' >&2; exit 1
STUB

  cat > "$R/stub/git" <<'STUB'
#!/bin/bash
# 记录每一次 clone，供"幂等"断言计数
if [ "${1:-}" = "clone" ]; then
  target=""
  for a in "$@"; do case "$a" in http*) repo="$a" ;; esac; done
  target="${repo##*/}"; target="${target%.git}"
  echo "$target" >> "$STUB_STATE/clones"
  mkdir -p "$target/.git"
  case "$target" in ComfyUI-Spectrum-MiniMax-H3) : > "$STUB_STATE/spectrum_loaded" ;; esac
  exit 0
fi
case "${1:-}${2:-}" in
  *describe*) echo "${STUB_COMFY_TAG:-v0.30.0}"; exit 0 ;;
  *rev-parse*) echo "deadbee"; exit 0 ;;
esac
exit 0
STUB

  cat > "$R/stub/supervisorctl" <<'STUB'
#!/bin/bash
case "${1:-}" in
  pid)     printf '%s' "${STUB_COMFY_PID:-}" ;;   # 空 = 模拟 supervisorctl 失败
  restart) echo "stub-restart $2" ;;
  *)       echo "stub-supervisor $*" ;;
esac
exit 0
STUB

  cat > "$R/stub/apt-get" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$R/stub/flock" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$R/stub/nvidia-smi" <<'STUB'
#!/bin/bash
echo "12.0"
STUB
  cat > "$R/stub/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$R/stub/stdbuf" <<'STUB'
#!/bin/bash
shift; exec "$@"
STUB
  cat > "$R/stub/timeout" <<'STUB'
#!/bin/bash
shift; exec "$@"
STUB
  chmod +x "$R/stub"/*

  # venv 里的 python / pip 是绝对路径调用（$VENV_ROOT 覆盖），不走 PATH
  mkdir -p "$R/venv/bin"
  cat > "$R/venv/bin/python" <<'STUB'
#!/bin/bash
# -c "import sageattention" → 由 STUB_SAGE_OK 决定成败
case "$*" in
  *sageattention*) [ -n "${STUB_SAGE_OK:-}" ] && exit 0 || exit 1 ;;
esac
exit 0
STUB
  cat > "$R/venv/bin/pip" <<'STUB'
#!/bin/bash
[ "${1:-}" = "install" ] && echo "$*" >> "$STUB_STATE/pip_installs"
exit 0
STUB
  chmod +x "$R/venv/bin"/*
}

# 跑一次装机，返回退出码，输出进 $OUT
run_setup() {
  local R="$1"; shift
  export STUB_STATE="$R/state"; mkdir -p "$STUB_STATE"
  export PATH="$R/stub:$PATH"
  export WORKSPACE="$R" VENV_ROOT="$R/venv"
  export MODEL_LOG="$R/setup.log" SAGE_LOG="$R/sage.log"
  export ENV_FILE="$R/environment" PROC_DIR="$R/proc" API_BASE="http://stub-api"
  mkdir -p "$R/ComfyUI/custom_nodes" "$R/ComfyUI/models" "$R/ComfyUI/comfy_extras"
  mkdir -p "$R/ComfyUI/.git"                              # 让步骤 2 认为它是 git 仓库
  : > "$R/ComfyUI/comfy_extras/nodes_minimax_h3.py"       # 步骤 2 要确认 H3 节点在
  # ⚠️ 这里**不能** set -e：被测脚本自己就是 set -uo pipefail（不带 -e），
  #    而且 harness 后面全靠 `rc=$?` 分支，打开 -e 会让第一个非零返回直接掐掉整个测试。
  OUT="$(env "$@" bash "$UNDER_TEST" 2>&1)"
  return $?
}

# 小字节 fixture：所有 DiT 档位统一 103，断言就不用关心默认是哪一档
build_under_test() {
  sed \
    -e 's/34038894550/103/g' -e 's/66280487368/103/g' -e 's/40225724176/103/g' \
    -e 's/20970379616/103/g' -e 's/20958205608/103/g' \
    -e 's/51506295256/101/g' -e 's/5207808496/102/g' -e 's/605254808/100/g' \
    "$SOURCE_SCRIPT" > "$1"
}

# ═════════════════════════════════════════════════════════════════════════════
echo "被测脚本: $SOURCE_SCRIPT"

# ── 1) 默认 DiT 必须是 bf16 ───────────────────────────────────────────────────
DEFAULT_DIT="$(sed -n 's/.*H3_DIT_FILE:-\([^}]*\)}.*/\1/p' "$SOURCE_SCRIPT" | head -1)"
[ -n "$DEFAULT_DIT" ] || fail "解析不出默认 H3_DIT_FILE（脚本结构变了？）"
case "$DEFAULT_DIT" in
  *ref2va_bf16*) ok "默认 DiT = bf16 ($DEFAULT_DIT)" ;;
  *) fail "默认 DiT 不是 bf16，是 $DEFAULT_DIT" ;;
esac

# ── 2) 全绿一趟：下载原子落位 + Spectrum 装上 + 参数清洗 ──────────────────────
R1="$(mktemp -d)"; trap 'rm -rf "$R1" "${R2:-}" "${R3:-}"' EXIT
UNDER_TEST="$R1/setup.sh"; build_under_test "$UNDER_TEST"
make_stubs "$R1"
mkdir -p "$R1/proc/4242"
printf 'python\0main.py\0--port\0018188\0' > "$R1/proc/4242/cmdline"
printf 'COMFYUI_ARGS="--disable-auto-launch --port 18188 --highvram --disable-dynamic-vram"\n' > "$R1/environment"
run_setup "$R1" STUB_COMFY_PID=4242 STUB_SAGE_OK=1
rc=$?
[ "$rc" -eq 0 ] || fail "全绿场景退出码 $rc，期望 0"
ok "全绿场景 exit 0"

for spec in "$DEFAULT_DIT:103" \
            'text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors:101' \
            'vae/minimax_h3_video_vae_fp16.safetensors:102' \
            'vae/minimax_h3_audio_vae_fp32.safetensors:100'; do
  rel="${spec%:*}"; want="${spec##*:}"; f="$R1/ComfyUI/models/$rel"
  got=missing; [ -f "$f" ] && got="$(stat -c %s "$f")"
  [ "$got" = "$want" ] || fail "$rel got=$got want=$want"
  [ -e "$f.partial" ] && fail "$rel 完成后仍留着 .partial"
done
ok "4 个模型精确字节落位、无残留 .partial"

grep -q 'ComfyUI-Spectrum-MiniMax-H3' "$R1/state/clones" || fail "Spectrum 没被 clone"
ok "Spectrum 已 clone"
printf '%s\n' "$OUT" | grep -q 'OK   Spectrum 节点已注册' || fail "汇总里没确认 Spectrum 注册"
ok "汇总确认 Spectrum 节点已注册"

after="$(cat "$R1/environment")"
case "$after" in
  *--highvram*)             fail "--highvram 没被剥掉: $after" ;;
  *--disable-dynamic-vram*) fail "--disable-dynamic-vram 没被剥掉: $after" ;;
  *--disable-auto-launch*)  ok "COMFYUI_ARGS 已清洗且保留了正常 flag" ;;
  *) fail "COMFYUI_ARGS 被清过头了: $after" ;;
esac
printf '%s\n' "$OUT" | grep -q 'OK   DynamicVRAM 开着' || fail "干净 cmdline 应报 OK"
ok "cmdline 干净 → 报 OK"

# ── 3) 幂等：原地重跑，不重复 clone、模型全跳过 ───────────────────────────────
before_clones="$(wc -l < "$R1/state/clones")"
run_setup "$R1" STUB_COMFY_PID=4242 STUB_SAGE_OK=1
rc=$?
[ "$rc" -eq 0 ] || fail "幂等重跑退出码 $rc，期望 0"
after_clones="$(wc -l < "$R1/state/clones")"
[ "$before_clones" = "$after_clones" ] || fail "重跑又 clone 了一次（$before_clones→$after_clones）"
ok "幂等重跑：无重复 clone"
printf '%s\n' "$OUT" | grep -q '已完整，跳过' || fail "重跑没打出'已完整，跳过'（会看着像卡住）"
ok "幂等重跑：模型逐个'已完整，跳过'有出声"

# ── 4) ⚠️ 假通过回归：supervisorctl 拿不到 pid 时必须报 ??，不能报 OK ─────────
R2="$(mktemp -d)"; UNDER_TEST="$R2/setup.sh"; build_under_test "$UNDER_TEST"
make_stubs "$R2"
printf 'COMFYUI_ARGS="--port 18188"\n' > "$R2/environment"
run_setup "$R2" STUB_COMFY_PID= STUB_SAGE_OK=1 || true
printf '%s\n' "$OUT" | grep -q '??   读不到 comfyui 命令行' \
  || fail "supervisorctl 失败时没报'读不到命令行'"
printf '%s\n' "$OUT" | grep -q 'OK   DynamicVRAM 开着' \
  && fail "**假通过**：读不到命令行却报了 OK DynamicVRAM"
ok "读不到 cmdline → 报 ?? 而非假 OK"

# ── 5) 脏 cmdline 必须判 BAD 且整体失败 ───────────────────────────────────────
R3="$(mktemp -d)"; UNDER_TEST="$R3/setup.sh"; build_under_test "$UNDER_TEST"
make_stubs "$R3"
mkdir -p "$R3/proc/777"
printf 'python\0main.py\0--disable-dynamic-vram\0' > "$R3/proc/777/cmdline"
printf 'COMFYUI_ARGS="--port 18188"\n' > "$R3/environment"
run_setup "$R3" STUB_COMFY_PID=777 STUB_SAGE_OK=1
rc=$?
printf '%s\n' "$OUT" | grep -q 'BAD  --disable-dynamic-vram 仍在生效命令行里' \
  || fail "脏 cmdline 没判 BAD"
[ "$rc" -ne 0 ] || fail "脏 cmdline 应让整体失败，却退出 0"
ok "脏 cmdline → BAD 且整体退出非 0"

# ── 6) NO_SPECTRUM / NO_SAGE 开关 ─────────────────────────────────────────────
R4="$(mktemp -d)"; UNDER_TEST="$R4/setup.sh"; build_under_test "$UNDER_TEST"
make_stubs "$R4"
mkdir -p "$R4/proc/4242"; printf 'python\0main.py\0' > "$R4/proc/4242/cmdline"
printf 'COMFYUI_ARGS="--port 18188"\n' > "$R4/environment"
run_setup "$R4" STUB_COMFY_PID=4242 NO_SPECTRUM=1 NO_SAGE=1 || true
grep -q 'Spectrum' "$R4/state/clones" 2>/dev/null && fail "NO_SPECTRUM=1 却还是 clone 了"
printf '%s\n' "$OUT" | grep -q 'NO_SPECTRUM=1 → 跳过' || fail "NO_SPECTRUM 没打跳过日志"
printf '%s\n' "$OUT" | grep -q 'NO_SAGE=1 → 跳过'     || fail "NO_SAGE 没打跳过日志"
grep -q 'SageAttention' "$R4/state/pip_installs" 2>/dev/null && fail "NO_SAGE=1 却还是装了 Sage"
ok "NO_SPECTRUM=1 / NO_SAGE=1 都真的跳过"
rm -rf "$R4"

echo
echo "PASS: h3-setup.sh 全部 $PASSED 项断言通过"
