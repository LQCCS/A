#!/bin/bash
# 回归：禁用 Xet 后，hf 对 >50GB 文件报错时，装机脚本必须走可续传的直连 HTTP，
# 并且只有精确字节数匹配才把 .partial 原子落位为最终模型。
set -uo pipefail

SOURCE_SCRIPT="${1:?usage: test_h3_provision.sh /path/to/h3-provision.sh}"
ROOT=/tmp/h3-provision-test
rm -rf "$ROOT"
mkdir -p \
  "$ROOT/ComfyUI/comfy_extras" \
  "$ROOT/ComfyUI/custom_nodes" \
  "$ROOT/stub"
touch "$ROOT/ComfyUI/comfy_extras/nodes_minimax_h3.py"
: > "$ROOT/ComfyUI/requirements.txt"

cat > "$ROOT/stub/hf" <<'STUB'
#!/bin/bash
if [ "${1:-}" = download ] && [ "${2:-}" = --help ]; then
  echo 'usage: hf download [--max-workers INTEGER]'
  exit 0
fi
echo 'Error: Invalid value. The file is too large to be downloaded using the regular download method.' >&2
exit 2
STUB

cat > "$ROOT/stub/curl" <<'STUB'
#!/bin/bash
out=''
url=''
has_internal_retry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) out="$2"; shift 2 ;;
    --retry|--retry-delay) has_internal_retry=1; shift 2 ;;
    --retry-all-errors) has_internal_retry=1; shift ;;
    *) url="$1"; shift ;;
  esac
done
case "${url##*/}" in
  # 所有 DiT 档位都给 103：本测试跑脚本的当前默认 DiT，默认改了也不用动这里
  minimax_h3_ref2va_*.safetensors) size=103 ;;
  qwen3vl_32b_minimax_h3_bf16.safetensors) size=101 ;;
  minimax_h3_video_vae_fp16.safetensors) size=102 ;;
  minimax_h3_audio_vae_fp32.safetensors) size=100 ;;
  *) echo "unexpected URL: $url" >&2; exit 22 ;;
esac
[ -n "$out" ] || { echo 'missing curl output path' >&2; exit 2; }
mkdir -p "$(dirname "$out")"
if [ "$has_internal_retry" -eq 1 ]; then
  # Characterize curl -C - + --retry after a transient transfer: a retry can
  # append an overlapping tail because the resume offset is not recalculated.
  head -c "$size" /dev/zero > "$out"
  printf x >> "$out"
  echo 'stub-overlapping-internal-retry' >&2
  exit 0
fi
got=$(stat -c '%s' "$out" 2>/dev/null || echo 0)
if [ "$got" -eq 0 ]; then
  head -c "$((size / 2))" /dev/zero > "$out"
  echo 'stub-transient-transfer-error' >&2
  exit 18
fi
head -c "$((size - got))" /dev/zero >> "$out"
echo "stub-http-206 ${url##*/} bytes=$size"
STUB

# aria2c 桩：**必须有**，否则测试结果取决于宿主装没装 aria2——
# 宿主有真 aria2c 时脚本会走 aria2 分支去真连 HF（慢、要网、非确定）。
# 这里让它"存在但下不动"，从而确定性地逼出本测试要验的 curl 续传兜底路径。
cat > "$ROOT/stub/aria2c" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "aria2 version 1.stub"; exit 0; }
echo 'stub-aria2c-refuses' >&2
exit 1
STUB

cat > "$ROOT/stub/flock" <<'STUB'
#!/bin/bash
exit 0
STUB

cat > "$ROOT/stub/pip" <<'STUB'
#!/bin/bash
exit 0
STUB

cat > "$ROOT/stub/python" <<'STUB'
#!/bin/bash
echo '1.18.0'
exit 0
STUB

cat > "$ROOT/stub/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = describe ]; then echo 'v0.30.0'; fi
exit 0
STUB

cat > "$ROOT/stub/supervisorctl" <<'STUB'
#!/bin/bash
echo "stub-supervisor $*"
exit 0
STUB

cat > "$ROOT/stub/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB

chmod +x "$ROOT/stub"/*

# 用手工核对的小字节 fixture 替换真实模型大小；下载控制流保持原样。
# ⚠️ **所有 DiT 档位都要打桩、且都打成同一个 103**：本测试不设 H3_DIT_FILE，
#    故意跑脚本的**当前默认 DiT**（那才是真正会发货的路径）。默认值一改
#    （如 2026-08-22 int8→bf16），只给单一档位打桩会让测试假失败。
#    全部打成同一个尺寸，下面的断言就不用关心默认到底是哪一档。
sed \
  -e 's/34038894550/103/g' \
  -e 's/66280487368/103/g' \
  -e 's/40225724176/103/g' \
  -e 's/20970379616/103/g' \
  -e 's/20958205608/103/g' \
  -e 's/51506295256/101/g' \
  -e 's/5207808496/102/g' \
  -e 's/605254808/100/g' \
  "$SOURCE_SCRIPT" > "$ROOT/provision-under-test.sh"

# 从被测脚本里解析出默认 DiT —— 断言跟着它走，而不是写死某个文件名
DEFAULT_DIT="$(sed -n 's/.*H3_DIT_FILE:-\([^}]*\)}.*/\1/p' "$SOURCE_SCRIPT" | head -1)"
if [ -z "$DEFAULT_DIT" ]; then
  echo "FAIL: 解析不出默认 H3_DIT_FILE（脚本结构变了？）"
  exit 1
fi
echo "被测默认 DiT: $DEFAULT_DIT"

export PATH="$ROOT/stub:$PATH"
export WORKSPACE="$ROOT"
export MODEL_LOG="$ROOT/provision.log"

set +e
output="$(bash "$ROOT/provision-under-test.sh" 2>&1)"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  printf '%s\n' "$output"
  echo "FAIL: provisioning exited $status; expected direct HTTP fallback to succeed"
  exit 1
fi

for spec in \
  "$DEFAULT_DIT:103" \
  'text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors:101' \
  'vae/minimax_h3_video_vae_fp16.safetensors:102' \
  'vae/minimax_h3_audio_vae_fp32.safetensors:100'
do
  rel="${spec%:*}"
  expected="${spec##*:}"
  file="$ROOT/ComfyUI/models/$rel"
  got=missing
  [ -f "$file" ] && got="$(stat -c %s "$file")"
  if [ "$got" != "$expected" ]; then
    printf '%s\n' "$output"
    echo "FAIL: $rel got=$got expected=$expected"
    exit 1
  fi
  if [ -e "$file.partial" ]; then
    echo "FAIL: completed model left a .partial file: $rel"
    exit 1
  fi
done

printf '%s\n' "$output"
echo 'PASS: outer retries resume exact atomic HTTP downloads without overlapping tails'
