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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
case "${url##*/}" in
  minimax_h3_ref2va_int8_convrot.safetensors) size=103 ;;
  qwen3vl_32b_minimax_h3_bf16.safetensors) size=101 ;;
  minimax_h3_video_vae_fp16.safetensors) size=102 ;;
  minimax_h3_audio_vae_fp32.safetensors) size=100 ;;
  *) echo "unexpected URL: $url" >&2; exit 22 ;;
esac
[ -n "$out" ] || { echo 'missing curl output path' >&2; exit 2; }
mkdir -p "$(dirname "$out")"
head -c "$size" /dev/zero > "$out"
echo "stub-http-206 ${url##*/} bytes=$size"
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
sed \
  -e 's/34038894550/103/g' \
  -e 's/51506295256/101/g' \
  -e 's/5207808496/102/g' \
  -e 's/605254808/100/g' \
  "$SOURCE_SCRIPT" > "$ROOT/provision-under-test.sh"

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
  'diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors:103' \
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
echo 'PASS: hf failure fell back to exact, atomically installed HTTP downloads'
