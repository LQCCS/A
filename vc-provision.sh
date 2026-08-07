#!/bin/bash
# Seed-VC 变声(zero-shot voice conversion) provisioning —— 用作 vast comfy 模板的 PROVISIONING_SCRIPT。
# 照 h3-provision.sh 的骨架写，跑在 vastai/comfy 镜像上（/workspace/ComfyUI + /venv/main + supervisord）。
#
# ⚠️ 不是 AI-Dock 版本：ai-dock/comfyui 那套（/opt/ai-dock/、/opt/ComfyUI/、micromamba）在本镜像上不存在。
#
# 做四件事：① apt 装 ffmpeg/portaudio ② clone ComfyUI_Seed-VC + 装依赖(torch 锁死不动)
#          ③ 下 ~3.4G 模型到 models/TTS/ ④ 重启 comfyui + 校验
# 完成后 vast 的 75-provisioning-manifest.sh 会写 /.provisioning_complete。
#
# 可选环境变量：
#   INSTALL_RVC=true   额外装 TTS-Audio-Suite（RVC，含训练）。同样 torch 锁死。
#
# 故意不用 set -e：单个模型/依赖失败不该中断整个 provisioning。
set -uo pipefail

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
CU="${WORKSPACE_DIR}/ComfyUI"
MODELS="${CU}/models"
NODES="${CU}/custom_nodes"
TTS="${MODELS}/TTS"
# ⚠️ 别写进 comfyui.log：supervisor 重启 comfyui 时会把它轮转成 comfyui.log.old，
# 排查时最有用的前半段（torch 校验/依赖 import/下载过程）就从"那个日志"里消失了。
# 用独立文件；同时 stdout 会被 vast 收进 /var/log/portal/provisioning.log，两边都全。
LOG="${VC_PROVISION_LOG:-/var/log/portal/vc-provision.log}"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

PY=/venv/main/bin/python
PIP=/venv/main/bin/pip

# ── 模型清单：(HF仓库, 仓库内路径, 落位目录) ──────────────────────────────────
# 路径由 seedvcnode.py 硬编码：models_dir/TTS/Seed-VC/*.pth|bin|pt、
# models_dir/TTS/{whisper-small,bigvgan_v2_22khz_80band_256x,bigvgan_v2_44khz_128band_512x}/
# 节点【不会】自动下载（README 明确要手动放），所以这里必须全下。
MODEL_SPECS=(
  # Seed-VC 主体（configs/*.yml 节点仓库自带，不用下）
  "Plachta/Seed-VC|DiT_seed_v2_uvit_whisper_small_wavenet_bigvgan_pruned.pth|${TTS}/Seed-VC"        # 440M 说话VC
  "Plachta/Seed-VC|DiT_seed_v2_uvit_whisper_base_f0_44k_bigvgan_pruned_ft_ema.pth|${TTS}/Seed-VC"   # 821M 44k/F0 跨音高
  "funasr/campplus|campplus_cn_common.bin|${TTS}/Seed-VC"                                           # 28M 说话人 embedding
  "lj1995/VoiceConversionWebUI|rmvpe.pt|${TTS}/Seed-VC"                                             # 181M F0 提取
  # 声码器：BigVGAN.from_pretrained(本地目录) 需要 config.json + bigvgan_generator.pt
  "nvidia/bigvgan_v2_22khz_80band_256x|bigvgan_generator.pt|${TTS}/bigvgan_v2_22khz_80band_256x"    # 449M
  "nvidia/bigvgan_v2_22khz_80band_256x|config.json|${TTS}/bigvgan_v2_22khz_80band_256x"
  "nvidia/bigvgan_v2_44khz_128band_512x|bigvgan_generator.pt|${TTS}/bigvgan_v2_44khz_128band_512x"  # 489M
  "nvidia/bigvgan_v2_44khz_128band_512x|config.json|${TTS}/bigvgan_v2_44khz_128band_512x"
  # whisper-small：只下 safetensors 权重 + 配置/分词器，跳过 pytorch_model.bin / tf / flax（各 967M 重复品）
  "openai/whisper-small|model.safetensors|${TTS}/whisper-small"                                     # 967M
  "openai/whisper-small|config.json|${TTS}/whisper-small"
  "openai/whisper-small|generation_config.json|${TTS}/whisper-small"
  "openai/whisper-small|preprocessor_config.json|${TTS}/whisper-small"
  "openai/whisper-small|tokenizer.json|${TTS}/whisper-small"
  "openai/whisper-small|tokenizer_config.json|${TTS}/whisper-small"
  "openai/whisper-small|special_tokens_map.json|${TTS}/whisper-small"
  "openai/whisper-small|added_tokens.json|${TTS}/whisper-small"
  "openai/whisper-small|normalizer.json|${TTS}/whisper-small"
  "openai/whisper-small|vocab.json|${TTS}/whisper-small"
  "openai/whisper-small|merges.txt|${TTS}/whisper-small"
)

# ── hf CLI（vast 装在 provisioner venv，系统 PATH 里未必有）+ 下载加速 ────────
setup_hf() {
  if ! command -v hf >/dev/null 2>&1; then
    export PATH="/opt/instance-tools/provisioner/venv/bin:/venv/main/bin:$PATH"
  fi
  HF_BIN="$(command -v hf || echo /venv/main/bin/hf)"
  HF_DIR="$(dirname "$HF_BIN")"
  "$HF_DIR/pip" install -q -U hf_transfer hf_xet >/dev/null 2>&1 || $PIP install -q -U hf_transfer hf_xet >/dev/null 2>&1 || true
  export HF_XET_HIGH_PERFORMANCE=1
  # 只在确认 hf_transfer 可 import 时才开，否则 hf 会因缺包直接报错、拖垮下载
  if "$HF_DIR/python" -c "import hf_transfer" >/dev/null 2>&1 || $PY -c "import hf_transfer" >/dev/null 2>&1; then
    export HF_HUB_ENABLE_HF_TRANSFER=1
    log "下载加速: hf_transfer + hf_xet 已启用"
  else
    log "下载加速: 仅 hf_xet（hf_transfer 不可用，跳过以免 hf 报错）"
  fi
}

download_one() {
  local repo="$1" f="$2" dir="$3" dest="$3/$2" attempt=1 max=5 delay=4
  if [ -s "$dest" ]; then log "已存在，跳过: $f"; return 0; fi
  mkdir -p "$dir"
  while [ $attempt -le $max ]; do
    log "下载 $repo/$f (第 $attempt/$max 次)..."
    if "$HF_BIN" download "$repo" "$f" --local-dir "$dir" 2>&1 | tail -2 | tee -a "$LOG"; then
      [ -s "$dest" ] && { log "✓ $f"; return 0; }
    fi
    log "✗ $f 失败，${delay}s 后重试..."; sleep $delay; delay=$((delay*2)); attempt=$((attempt+1))
  done
  log "[ERROR] 放弃: $repo/$f（$max 次都失败）"; return 1
}

# ── torch 护栏 ──────────────────────────────────────────────────────────────
# Seed-VC 的 requirements（funasr / descript-audio-codec / librosa …）会顺手把
# torch/torchaudio/numpy 换掉 → ComfyUI 地基塌。用 pip constraints 把地基版本钉死：
# pip 宁可报冲突也不会动它们。冲突时退化成【逐包安装】，坏一个不连累其余。
write_constraints() {
  $PY - > /tmp/vc_constraints.txt <<'PYEOF'
import importlib.metadata as md
for p in ("torch", "torchvision", "torchaudio", "numpy", "xformers"):
    try:
        print(f"{p}=={md.version(p)}")
    except Exception:
        pass
PYEOF
  log "torch 护栏(constraints):"; sed 's/^/    /' /tmp/vc_constraints.txt | tee -a "$LOG"
}

pip_guarded() {  # pip_guarded -r req.txt  /  pip_guarded pkgA pkgB
  $PIP install -q -c /tmp/vc_constraints.txt "$@" 2>&1 | tail -5 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

install_reqs_guarded() {  # $1 = requirements.txt 路径
  local req="$1"
  if pip_guarded -r "$req"; then log "✓ 依赖装好（torch 未动）"; return 0; fi
  log "[WARN] 整包安装有冲突，改逐包安装（坏一个不连累其余）..."
  local n_fail=0 pkg
  while IFS= read -r pkg; do
    pkg="$(echo "$pkg" | sed 's/#.*//' | xargs)"
    [ -z "$pkg" ] && continue
    pip_guarded "$pkg" || { log "[WARN] 装不上: $pkg"; n_fail=$((n_fail+1)); }
  done < "$req"
  log "逐包安装完成，失败 $n_fail 个"
  return 0
}

# 依赖冒烟：constraints 冲突退化成逐包安装时会有包装不上，这里点名报出来——
# 否则症状是"ComfyUI 里搜不到 Seed-VC 节点"，看不出缺谁。
check_imports() {
  log "依赖 import 冒烟测试..."
  $PY - 2>&1 <<'PYEOF' | tee -a "$LOG"
import importlib
mods = ["torch", "torchaudio", "transformers", "librosa", "huggingface_hub", "munch",
        "einops", "pydub", "dac", "soundfile", "sounddevice", "funasr", "hydra", "yaml", "dotenv"]
bad = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        bad.append(f"{m}({type(e).__name__}: {str(e)[:80]})")
print("[ERROR] import 失败: " + "; ".join(bad) if bad else "✓ 依赖 import 全通过")
PYEOF
}

# 节点加载校验。
# ⚠️ 不能查 ComfyUI 的 /object_info：provisioning 期间 /.provisioning 还在，comfyui.sh 会
# "startup paused until instance provisioning has completed"，ComfyUI 压根没起，查必超时。
# 也不能靠 grep comfyui.log（那时它还没扫过 custom_nodes，等于稳过 = 假阳性）。
# 直接在 venv 里按文件路径 import 节点模块——依赖缺了/版本不对会在这里原地炸出 traceback。
check_node_loaded() {
  log "节点 import 校验..."
  local out
  out="$($PY - 2>&1 <<PYEOF
import sys, importlib.util, traceback
NODE = "$NODES/ComfyUI_Seed-VC"
sys.path.insert(0, "$CU")     # folder_paths / comfy
sys.path.insert(0, NODE)      # seed_vc 包（目录名带横杠，只能按路径加载）
sys.argv = [sys.argv[0]]      # 别让 comfy.cli_args 吃到我们的参数
try:
    spec = importlib.util.spec_from_file_location("seedvcnode", NODE + "/seedvcnode.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    names = list(getattr(m, "NODE_CLASS_MAPPINGS", {}))
    print("✓ 节点 import 成功，注册: " + ", ".join(names) if names else "[ERROR] import 成功但无 NODE_CLASS_MAPPINGS")
except Exception:
    print("[ERROR] 节点 import 失败:"); traceback.print_exc()
PYEOF
)"
  echo "$out" | tee -a "$LOG"
  # 用本次输出判定，不是 grep 日志文件——重跑时旧的成功行会造成假阳性
  echo "$out" | grep -q "✓ 节点 import 成功"
}

torch_intact() {
  local before="$1" after
  after="$($PY -c 'import torch;print(torch.__version__)' 2>/dev/null)"
  if [ "$before" != "$after" ]; then
    log "[ERROR] torch 被改动了！$before -> $after —— ComfyUI 可能起不来，需人工回滚"
    return 1
  fi
  log "✓ torch 未被改动: $after"
}

# ── 可选：RVC（TTS-Audio-Suite）。同样走 constraints，不动 torch。 ───────────
install_rvc() {
  [ "${INSTALL_RVC:-}" != "true" ] && { log "INSTALL_RVC 未开，跳过 RVC"; return 0; }
  log "INSTALL_RVC=true → 装 TTS-Audio-Suite（RVC）..."
  local path="$NODES/TTS-Audio-Suite"
  if [ ! -d "$path" ]; then
    git clone --depth 1 https://github.com/diodiogod/TTS-Audio-Suite "$path" 2>&1 | tail -1 | tee -a "$LOG"
  fi
  [ -f "$path/requirements.txt" ] && install_reqs_guarded "$path/requirements.txt"
  log "⚠️ RVC base 模型(HuBERT/rmvpe/pretrained)由节点首跑自动下到 models/TTS/RVC/。"
}

main() {
  log "===== Seed-VC provisioning 开始 ====="
  [ -f /venv/main/bin/activate ] && . /venv/main/bin/activate
  [ -d "$CU" ] || { log "[ERROR] 找不到 $CU —— 镜像不对？"; return 1; }
  # 镜像换了路径时回落到 PATH 上的 python，别让 constraints 生成静默失败(那样 torch 就没护栏了)
  command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python3 || command -v python)"
  command -v "$PIP" >/dev/null 2>&1 || PIP="$PY -m pip"

  # 1) 系统包：ffmpeg(音频解码) + libportaudio2(sounddevice 的 so 依赖，缺了 import 就炸)
  log "装系统包 ffmpeg / libportaudio2 ..."
  local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO apt-get update -qq 2>&1 | tail -1 | tee -a "$LOG" || true
  $SUDO apt-get install -y -qq ffmpeg libportaudio2 2>&1 | tail -2 | tee -a "$LOG" || log "[WARN] apt 装包失败，继续"

  # 2) 节点 + 依赖（torch 钉死）
  local torch_before; torch_before="$($PY -c 'import torch;print(torch.__version__)' 2>/dev/null)"
  write_constraints
  local node="$NODES/ComfyUI_Seed-VC"
  if [ -d "$node" ]; then
    log "节点已存在，git pull"; ( cd "$node" && git pull 2>&1 | tail -1 | tee -a "$LOG" ) || true
  else
    log "clone ComfyUI_Seed-VC ..."
    git clone --depth 1 https://github.com/billwuhao/ComfyUI_Seed-VC "$node" 2>&1 | tail -1 | tee -a "$LOG"
  fi
  [ -f "$node/requirements.txt" ] || { log "[ERROR] clone 失败，没有 requirements.txt"; return 1; }
  install_reqs_guarded "$node/requirements.txt"
  install_rvc
  torch_intact "$torch_before"
  check_imports

  # 3) 模型（约 3.4G）
  setup_hf
  log "下模型（Seed-VC 全套，约 3.4G）..."
  local failed=0 spec
  for spec in "${MODEL_SPECS[@]}"; do
    IFS='|' read -r repo f dir <<< "$spec"
    download_one "$repo" "$f" "$dir" || failed=$((failed+1))
  done

  # 4) 节点校验 + 按需重启 comfyui
  local node_ok=1; check_node_loaded || node_ok=0
  # 首次开机不用重启：vast 会在 provisioning 结束后自己起 comfyui，那时模型/节点都已就位。
  # 只有在已跑起来的机器上重跑本脚本（更新节点/补模型）时才需要重启去刷新。
  if [ -f /.provisioning ]; then
    log "首次开机：comfyui 由 vast 在 provisioning 结束后自动启动，不重启"
  else
    supervisorctl restart comfyui 2>&1 | tail -1 | tee -a "$LOG" || true
  fi

  # 5) 校验
  local ok=1 spec2
  for spec2 in "${MODEL_SPECS[@]}"; do
    IFS='|' read -r repo f dir <<< "$spec2"
    if [ -s "$dir/$f" ]; then log "OK  $(basename "$dir")/$f ($(du -h "$dir/$f" 2>/dev/null | cut -f1))"
    else log "[ERROR] 缺 $dir/$f"; ok=0; fi
  done
  if [ "$failed" -gt 0 ] || [ "$ok" -ne 1 ] || [ "$node_ok" -ne 1 ]; then
    log "[ERROR] provisioning 视为失败（模型缺失或节点没加载上）"; return 1
  fi
  log "===== ✓ Seed-VC provisioning 完成 ====="
  log "ComfyUI 里搜节点 'Seed-VC'；示例工作流: $node/workflow-examples/变声.json"
}

main
