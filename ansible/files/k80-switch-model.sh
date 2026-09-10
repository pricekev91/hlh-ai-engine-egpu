#!/usr/bin/env bash
# k80-switch-model.sh
# Version: 2.1.1-k80-vulkan
#   2.1.1-k80-vulkan - Add --flash-attn on (was in hlh 1.6.2, missing in k80 2.1.0) for ctx efficiency + speed
#   2.1.0-k80-vulkan - Merge hlh 1.6.3 into k80 2.0.0: add hlh features (selectable -ngl 99/75/50/25/custom,
#                     MTP n-max prompt 1-16, final command breakdown, draft/ngl state) but keep K80 Vulkan
#                     dual GK210 24GB, batch 512, nvidia-smi/nvtop/vulkaninfo, no ROCm/DFlash optional
# Description: Interactive model switcher for llama.cpp ai-engine service (Tesla K80 dual GK210 Vulkan egpu)
# Supports: model selection, ctx-size, KV cache quantization, speculative decoding method (MTP draft / ngram / DFlash / none)
# Changelog:
#   2.1.0-k80-vulkan - Merge from hlh 1.6.3 + k80 2.0.0: selectable ngl, MTP n-max prompt, breakdown, keep Vulkan MTP
#   2.0.0-k80-vulkan - Vulkan-only: banner 24GB, -ngl 99, --batch-size 512, verify via vulkaninfo + nvidia-smi monitoring
#   1.6.3 - Added MTP draft n-max prompt (default 5 MoE / 3 dense); now prompts for token count after selecting MTP draft
#   1.6.2 - Exposed -ngl as selectable variable (99/75/50/25/custom, default 99), added --flash-attn on, added final breakdown
#   1.6.1 - Fixed readiness check: probe /health HTTP endpoint
set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
# MTP draft n-max: 5 for MoE models (e.g. Qwen3.6-35B-A3B-MTP), 3 for dense
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-}"
NGRAM_N_MATCH="${NGRAM_N_MATCH:-24}"
NGRAM_N_MIN="${NGRAM_N_MIN:-48}"
NGRAM_N_MAX="${NGRAM_N_MAX:-64}"
# DFlash draft n-max (kept from hlh, optional for k80 Vulkan if draft GGUF present)
DFLASH_DRAFT_N_MAX="${DFLASH_DRAFT_N_MAX:-7}"

is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}
is_dflash_model() {
  [[ "$(basename "$1")" =~ [Dd][Ff]lash ]]
}
model_family() {
  local base
  base="$(basename "$1")"
  base="${base%.gguf}"
  base="${base%%-[Qq][0-9]*}"
  base="${base%%-[Ii][Qq]*}"
  base="${base%%-[Uu][Dd]*}"
  base="${base%%-[Dd][Ff]lash*}"
  echo "$base"
}
is_moe_model() {
  [[ "$(basename "$1")" =~ -A[0-9]+B- ]]
}
rewrite_execstart() {
  local model="$1" ctx="$2" kv="$3" spec_flags="$4" ngl="$5"
  local tmp_file
  tmp_file="$(mktemp)"
  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"
  awk -v model="$model" -v ctx="$ctx" -v kv="$kv" -v spec_flags="$spec_flags" -v ngl="$ngl" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*llama-server/ {
      done=1
      print "ExecStart=/opt/llama.cpp/build/bin/llama-server \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 80 \\"
      print "  --ctx-size " ctx " \\"
      print "  -ngl " ngl " \\"
      print "  --batch-size 512 \\"
      print "  --flash-attn on \\"
      print "  --cache-type-k " kv " \\"
      if (spec_flags != "") {
        print "  --cache-type-v " kv " \\"
        print "  " spec_flags " \\"
        print "  --parallel 1"
      } else {
        print "  --cache-type-v " kv " \\"
        print "  --parallel 1"
      }
      in_block=1
      next
    }
    in_block {
      if (/^Restart=/) { in_block=0; print }
      next
    }
    { print }
    END { if (!done) exit 42 }
  ' "$SYSTEMD_SERVICE" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "ERROR: Failed to rewrite ExecStart in $SYSTEMD_SERVICE" >&2
    echo "Service file may be corrupted or missing" >&2
    exit 1
  }
  mv "$tmp_file" "$SYSTEMD_SERVICE"
  echo "INFO: Successfully updated service configuration"
}

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        k80-switch-model.sh (Tesla K80 dual GK210 VULKAN egpu)   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  BACKEND  VULKAN (MTP enabled)  CUDA only for nvidia-smi/nvtop  ║"
echo "║  VRAM BUDGET  K80 dual 2×12GB = 24GB board (Vulkan devices 0,1)  ║"
echo "║  Model Weights (fixed) + KV cache (scales with ctx) = total     ║"
echo "║    70B Q2_K      ~17 GB   70B Q3_K_M   ~26 GB                    ║"
echo "║    70B Q4_K_M    ~38 GB   70B Q6_K     ~54 GB                    ║"
echo "║    35B Q4_K_M    ~21 GB   35B Q5_K_M   ~25 GB                    ║"
echo "║    30B Q4_K_XL   ~16 GB   27B Q5_K_M   ~18 GB                    ║"
echo "║                  KV q4_0    KV q6_0    KV q8_0  (per 24GB)       ║"
echo "║    64K context   ~ 8 GB     ~12 GB     ~18 GB  -> fits 30B Q4    ║"
echo "║    32K context   ~ 4 GB      ~ 6 GB     ~ 9 GB  -> fits 35B Q4   ║"
echo "║    16K context   ~ 2 GB      ~ 3 GB     ~ 5 GB                  ║"
echo "║     8K context   ~ 1 GB      ~ 2 GB     ~ 3 GB                  ║"
echo "║  K80 needs q4_0 for 32K+ on 30B+; 8K allows q8_0                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

CUR_MODEL=$(grep -- '--model '         "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model")         print $(i+1)}')
CUR_CTX=$(  grep -- '--ctx-size '      "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--ctx-size")      print $(i+1)}') || CUR_CTX="(not set)"
CUR_KV_K=$( grep -- '--cache-type-k '  "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--cache-type-k")  print $(i+1)}') || CUR_KV_K="(not set)"
CUR_KV_V=$( grep -- '--cache-type-v '  "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--cache-type-v")  print $(i+1)}') || CUR_KV_V="(not set)"
CUR_SPEC=$( grep -- '--spec-type '     "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--spec-type")     print $(i+1)}') || CUR_SPEC="none"
CUR_SPEC="${CUR_SPEC:-none}"
CUR_DRAFT=$(grep -- '--model-draft '  "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model-draft")  print $(i+1)}') || CUR_DRAFT=""
CUR_NGL=$(grep -oP '(?<=-ngl )\S+' "$SYSTEMD_SERVICE" 2>/dev/null | head -n1 || grep -- '-ngl ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="-ngl") print $(i+1)}' ) || CUR_NGL="(not set)"
CUR_FLASH=$(grep -o -- '--flash-attn[^\\]*' "$SYSTEMD_SERVICE" 2>/dev/null | head -n1 || echo "not set")
K80_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || echo "?")

echo "  Model directory : $MODEL_DIR"
echo "  Currently active: $CUR_MODEL"
echo "  ctx-size        : ${CUR_CTX:-(not set)}"
echo "  KV cache (K/V)  : ${CUR_KV_K} / ${CUR_KV_V}"
echo "  Spec decode     : $CUR_SPEC"
echo "  Draft model     : ${CUR_DRAFT:-none}"
echo "  -ngl (GPU layers): ${CUR_NGL:-(not set)}"
echo "  Flash Attention : $CUR_FLASH"
echo "  Vulkan devices  : $(vulkaninfo --summary 2>&1 | grep -c "GPU" || echo "?") (nvidia-smi shows $K80_COUNT K80 GPUs)"
echo "  nvidia-smi      :"
nvidia-smi -L 2>&1 | sed 's/^/    /' || echo "    nvidia-smi failed"
echo "  vulkaninfo      :"
vulkaninfo --summary 2>&1 | sed 's/^/    /' | head -n 20 || echo "    vulkaninfo failed"
echo ""

mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [ "${#MODELS[@]}" -eq 0 ]; then
  echo "No .gguf models found in $MODEL_DIR."
  exit 1
fi

echo "Available models:"
for i in "${!MODELS[@]}"; do
  if is_mtp_model "${MODELS[$i]}"; then
    printf "  %2d) %s  [MTP]\n" $((i+1)) "${MODELS[$i]}"
  elif is_dflash_model "${MODELS[$i]}"; then
    printf "  %2d) %s  [DFlash]\n" $((i+1)) "${MODELS[$i]}"
  else
    printf "  %2d) %s\n" $((i+1)) "${MODELS[$i]}"
  fi
done

read -rp "Select model number to activate: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "Invalid selection."
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"

# DFlash draft pairing (from hlh, optional for k80 if draft present)
DFLASH_DRAFT=""
if ! is_dflash_model "$NEW_MODEL"; then
  FAMILY="$(model_family "$NEW_MODEL")"
  for m in "${MODELS[@]}"; do
    if is_dflash_model "$m" && [[ "$(model_family "$m")" == "$FAMILY" ]]; then
      DFLASH_DRAFT="$m"
      break
    fi
  done
fi

echo ""
echo "Context size options:"
echo "   1) 98304  (96K)  — maximum long-context (needs 2GB KV q4_0, unlikely on K80 12GB)"
echo "   2) 73728  (72K)  — extended long-context"
echo "   3) 65536  (64K)  — full long-context"
echo "   4) 32768  (32K)  — recommended for 30B Q4 on K80"
echo "   5) 16384  (16K)  — quarter, minimal KV usage"
echo "   6)  8192   (8K)  — minimal, maximum VRAM headroom"
echo "   7) Custom         — enter manually"

read -rp "Select context size [default: 32768]: " CTX_CHOICE
case "${CTX_CHOICE:-4}" in
  1) NEW_CTX=98304  ;;
  2) NEW_CTX=73728  ;;
  3) NEW_CTX=65536  ;;
  4) NEW_CTX=32768  ;;
  5) NEW_CTX=16384  ;;
  6) NEW_CTX=8192   ;;
  7)
    read -rp "Enter custom ctx-size: " NEW_CTX
    if ! [[ "$NEW_CTX" =~ ^[0-9]+$ ]]; then
      echo "Invalid ctx-size."
      exit 1
    fi
    ;;
  *) NEW_CTX=32768 ;;
esac

echo ""
echo "KV cache quantization (applies to both K and V cache):"
echo "   1) q8_0  — highest quality,  ~2x VRAM vs q4"
echo "   2) q6_0  — very good quality, ~1.5x VRAM vs q4"
echo "   3) q4_0  — recommended for K80, lowest VRAM"
echo ""
echo "   Recommendation for K80 32K: q4_0 (saves 5GB vs q8_0)"

read -rp "Select KV cache quant [default: q4_0]: " KV_CHOICE
case "${KV_CHOICE:-3}" in
  1) NEW_KV="q8_0" ;;
  2) NEW_KV="q6_0" ;;
  3) NEW_KV="q4_0" ;;
  *) NEW_KV="q4_0" ;;
esac

echo ""
echo "GPU layers (-ngl) — how many layers to offload to GPU:"
echo "   1) 99  — full GPU offload (default, max performance)"
echo "   2) 75  — high GPU usage"
echo "   3) 50  — balanced"
echo "   4) 25  — low GPU usage (more CPU, less VRAM)"
echo "   5) Custom — enter manually (0-99)"

read -rp "Select -ngl [default: 99]: " NGL_CHOICE
case "${NGL_CHOICE:-1}" in
  1) NEW_NGL=99 ;;
  2) NEW_NGL=75 ;;
  3) NEW_NGL=50 ;;
  4) NEW_NGL=25 ;;
  5)
    read -rp "Enter custom -ngl value [0-99]: " NEW_NGL
    if ! [[ "$NEW_NGL" =~ ^[0-9]+$ ]] || (( NEW_NGL < 0 || NEW_NGL > 99 )); then
      echo "Invalid -ngl value."
      exit 1
    fi
    ;;
  *) NEW_NGL=99 ;;
esac

if is_mtp_model "$NEW_MODEL" || [ -n "$DFLASH_DRAFT" ]; then
  if is_mtp_model "$NEW_MODEL"; then
    if [ -z "$MTP_DRAFT_N_MAX" ]; then
      if is_moe_model "$NEW_MODEL"; then
        MTP_DRAFT_N_MAX=5
      else
        MTP_DRAFT_N_MAX=3
      fi
    fi
    DEFAULT_SPEC=1
  elif [ -n "$DFLASH_DRAFT" ]; then
    DEFAULT_SPEC=6
  fi
  echo ""
  echo "Speculative decoding method:"
  if is_mtp_model "$NEW_MODEL"; then
    echo "   1) MTP draft     — use the model's MTP heads (default, n-max $MTP_DRAFT_N_MAX) [Vulkan OK]"
  else
    echo "   1) MTP draft     — (not available: model is not an MTP model)"
  fi
  echo "   2) ngram-mod     — n-gram matching, self-speculative (tunable)"
  echo "   3) ngram-map-k4v — n-gram keys + 4 m-gram values (fast self-speculation)"
  echo "   4) ngram-map-k   — n-gram keys only"
  echo "   5) ngram-simple  — simple n-gram lookup"
  if [ -n "$DFLASH_DRAFT" ]; then
    echo "   6) DFlash2       — distilled flash draft: $(basename "$DFLASH_DRAFT")"
  fi
  echo "   7) none          — disable speculative decoding"

  read -rp "Select method [default: $DEFAULT_SPEC]: " SPEC_CHOICE
  case "${SPEC_CHOICE:-$DEFAULT_SPEC}" in
    1)
      if ! is_mtp_model "$NEW_MODEL"; then
        echo "ERROR: MTP draft requires an MTP model."
        exit 1
      fi
      read -rp "  MTP draft tokens (n-max) [default: $MTP_DRAFT_N_MAX]: " MTP_N_CHOICE
      if [[ -n "$MTP_N_CHOICE" ]]; then
        if ! [[ "$MTP_N_CHOICE" =~ ^[0-9]+$ ]] || (( MTP_N_CHOICE < 1 || MTP_N_CHOICE > 16 )); then
          echo "Invalid n-max value (must be 1-16)."
          exit 1
        fi
        MTP_DRAFT_N_MAX="$MTP_N_CHOICE"
      fi
      NEW_METHOD="draft-mtp"
      SPEC_FLAGS="--spec-type draft-mtp --spec-draft-n-max $MTP_DRAFT_N_MAX"
      ;;
    2)
      NEW_METHOD="ngram-mod"
      read -rp "  Customize ngram-mod params? [y/N]: " NGRAM_CUSTOM
      if [[ "$NGRAM_CUSTOM" =~ ^[Yy]$ ]]; then
        read -rp "    n-match (lookup length, default $NGRAM_N_MATCH): " TMP_N
        [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MATCH="$TMP_N"
        read -rp "    n-min (draft min tokens, default $NGRAM_N_MIN): " TMP_N
        [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MIN="$TMP_N"
        read -rp "    n-max (draft max tokens, default $NGRAM_N_MAX): " TMP_N
        [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MAX="$TMP_N"
      fi
      SPEC_FLAGS="--spec-type ngram-mod --spec-ngram-mod-n-match $NGRAM_N_MATCH --spec-ngram-mod-n-min $NGRAM_N_MIN --spec-ngram-mod-n-max $NGRAM_N_MAX"
      ;;
    3)
      NEW_METHOD="ngram-map-k4v"
      SPEC_FLAGS="--spec-type ngram-map-k4v"
      ;;
    4)
      NEW_METHOD="ngram-map-k"
      SPEC_FLAGS="--spec-type ngram-map-k"
      ;;
    5)
      NEW_METHOD="ngram-simple"
      SPEC_FLAGS="--spec-type ngram-simple"
      ;;
    6)
      if [ -z "$DFLASH_DRAFT" ]; then
        echo "ERROR: No DFlash draft model found for $NEW_MODEL"
        exit 1
      fi
      NEW_METHOD="dflash"
      SPEC_FLAGS="--spec-type draft-dflash --model-draft $DFLASH_DRAFT --spec-draft-n-max $DFLASH_DRAFT_N_MAX"
      ;;
    7|*)
      NEW_METHOD="none"
      SPEC_FLAGS=""
      ;;
  esac
else
  NEW_METHOD="none"
  SPEC_FLAGS=""
fi

echo ""
echo "  New model   : $NEW_MODEL"
echo "  ctx-size    : $NEW_CTX"
echo "  -ngl        : $NEW_NGL"
echo "  KV cache    : $NEW_KV (K and V)"
echo "  Flash Attention : on ( --flash-attn on )"
if [ -n "$SPEC_FLAGS" ]; then
  echo "  Spec decode : $NEW_METHOD  $SPEC_FLAGS"
else
  echo "  Spec decode : $NEW_METHOD"
fi
echo ""
read -rp "Apply and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

rewrite_execstart "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$SPEC_FLAGS" "$NEW_NGL"

systemctl daemon-reload
systemctl restart "$SERVICE"

HEALTH_URL="http://127.0.0.1:80/health"
START_RESTARTS="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
OK=0
echo ""
echo "  Waiting for $SERVICE to load ($HEALTH_URL)..."
for i in {1..90}; do
  if curl -fsS -m 3 -o /dev/null "$HEALTH_URL" 2>/dev/null; then
    OK=1
    break
  fi
  NR="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
  ST="$(systemctl show -p ActiveState --value "$SERVICE" 2>/dev/null)"
  if [ "$ST" = "failed" ] || { [ -n "$NR" ] && [ "$NR" -gt "$START_RESTARTS" ]; }; then
    echo "  [✗] $SERVICE entered failed/crash-loop state (NRestarts=$NR)."
    break
  fi
  sleep 2
done

if [ "$OK" = "1" ]; then
  echo "  [✓] Switched to : $NEW_MODEL"
  echo "  [✓] ctx-size    : $NEW_CTX"
  echo "  [✓] -ngl        : $NEW_NGL"
  echo "  [✓] KV cache    : $NEW_KV (K and V)"
  echo "  [✓] Flash Attn  : on"
  echo "  [✓] Spec decode : $NEW_METHOD"
  if [ -n "$DFLASH_DRAFT" ] && [[ "$NEW_METHOD" == "dflash" ]]; then
    echo "  [✓] Draft model : $DFLASH_DRAFT"
  fi
  echo "  [✓] Service     : $SERVICE running (health OK)"
  echo ""
  echo "  Web UI ready at       : http://$(hostname -I | awk '{print $1}'):80"
  echo "  Verify GPU usage with  : nvidia-smi; nvtop; vulkaninfo --summary"
  echo "  Watch logs with       : journalctl -u $SERVICE -f"
else
  echo "  [✗] WARNING: $SERVICE did not start cleanly after switch!"
  echo "  Check logs with: journalctl -u $SERVICE -f"
  exit 1
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " FINAL COMMAND (exact ExecStart as written to systemd)"
echo "══════════════════════════════════════════════════════════════════"
systemctl cat "$SERVICE" 2>/dev/null | sed -n '/ExecStart/,/^Restart/p' | head -n 20
echo ""
echo " Breakdown of each flag:"
echo "  /opt/llama.cpp/build/bin/llama-server  — server binary"
echo "  --model $NEW_MODEL                     — model file (GGUF)"
echo "  --host 0.0.0.0 --port 80               — listen address"
echo "  --ctx-size $NEW_CTX                    — context window (tokens)"
echo "  -ngl $NEW_NGL                          — GPU layers offloaded (99=full GPU, 0=CPU only)"
echo "  --batch-size 512                       — batch size (prompt processing, K80 tuned)"
echo "  --flash-attn on                        — Flash Attention optimized kernel (ctx efficiency + speed)"
echo "  --cache-type-k $NEW_KV / --cache-type-v $NEW_KV — KV cache quantization (VRAM vs quality)"
if [ -n "$SPEC_FLAGS" ]; then
  echo "  $SPEC_FLAGS — speculative decoding ($NEW_METHOD)"
else
  echo "  (no --spec-type)                     — standard decoding"
fi
echo "  --parallel 1                           — parallel slots (concurrent requests)"
echo "══════════════════════════════════════════════════════════════════"
echo " Full reconstructed command:"
echo "  /opt/llama.cpp/build/bin/llama-server --model $NEW_MODEL --host 0.0.0.0 --port 80 --ctx-size $NEW_CTX -ngl $NEW_NGL --batch-size 512 --flash-attn on --cache-type-k $NEW_KV --cache-type-v $NEW_KV ${SPEC_FLAGS:+$SPEC_FLAGS }--parallel 1"
echo "══════════════════════════════════════════════════════════════════"
