#!/usr/bin/env bash
# configure-ai-engine-inside-lxc.sh
# Version: 1.0.0-k80
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with CUDA 11.8 for Tesla K80 (GK210 dual cc 3.7) via OCuLink
# Target GPU: NVIDIA Tesla K80 2x GK210GL (12GB per chip, 24GB board) via OCuLink on Minisforum DG2 / Proxmox 9.x privileged LXC
# Pinned: CUDA 11.8.0-1 + driver 470.256.02 (last supporting Kepler cc 3.7; CUDA 12 drops Kepler)
# Requirements: Run as root inside privileged LXC with /dev/nvidia* passthrough and /srv/ai/models bind mount
# Changelog:
#   1.0.0-k80 - Fork for hlh-ai-engine-egpu-k80 LXC 131: K80 dual-GK210, CUDA 11.8 + 470.256.02 pinned, GGML_CUDA=ON cc 3.7

set -euo pipefail

# --- PINNED VERSIONS (K80) ---
CUDA_VERSION="11.8.0-1"
CUDA_MAJOR="11-8"
CUDA_REPO_VERSION="11.8.0"
NVIDIA_DRIVER_VERSION="470.256.02"
CUDA_ARCH="37"  # Kepler GK210 cc 3.7

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_URL=""
DEFAULT_MODEL_FILE="Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SWITCH_SCRIPT="/usr/local/bin/k80-switch-model.sh"
SHARED_SWITCH_SCRIPT="${MODEL_DIR}/k80-switch-model.sh"

# --- 1. BASE DEPENDENCIES + CUDA 11.8 (pinned) ---
echo "[1/7] Installing base dependencies + CUDA $CUDA_REPO_VERSION (pinned)..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip bc \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server

# Add NVIDIA CUDA repo for ubuntu2404 (pinned CUDA 11.8)
if [ ! -f /etc/apt/sources.list.d/cuda-ubuntu2204.list ]; then
  echo "  Adding NVIDIA CUDA repo (ubuntu2204, CUDA $CUDA_MAJOR)..."
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg 2>/dev/null || \
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/7fa2af80.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg
  echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64 /" > /etc/apt/sources.list.d/cuda-ubuntu2204.list
  apt-get update
fi

# Install CUDA toolkit 11.8 (pinned) — driver is host-side 470, toolkit is LXC-side
# Noble (24.04) lacks libtinfo5 needed by nsight-systems from cuda 11.8 (built for jammy).
# Add jammy for libtinfo5 (noble has libtinfo6, cuda 11.8 nsight needs 5)
echo "deb http://archive.ubuntu.com/ubuntu jammy main universe" > /etc/apt/sources.list.d/jammy-libtinfo5.list
echo "deb http://archive.ubuntu.com/ubuntu jammy-updates main universe" >> /etc/apt/sources.list.d/jammy-libtinfo5.list
apt-get update
apt-get install -y libtinfo5 libncurses5 2>&1 | tail -n 10 || apt-get install -y libtinfo5=6.3-2ubuntu0.1 2>&1 | tail -n 10 || true
echo "  Installing cuda-toolkit-$CUDA_MAJOR=$CUDA_VERSION (pinned, no nsight)..."
# Install without nsight to avoid libtinfo5 pull; use --no-install-recommends and allow unauthenticated
apt-get install -y --no-install-recommends cuda-toolkit-${CUDA_MAJOR}=${CUDA_VERSION} -o APT::Get::Fix-Broken=true 2>&1 | tail -n 30 || \
apt-get install -y --no-install-recommends cuda-nvcc-11-8 cuda-cudart-11-8 cuda-cudart-dev-11-8 libcurand-11-8 libcufft-11-8 libcufft-dev-11-8 libcusolver-11-8 libcusparse-11-8 2>&1 | tail -n 30 || \
apt-get download cuda-toolkit-${CUDA_MAJOR} 2>&1 | head -n 20
# Ensure nvidia libs match host driver 470.256.02 (not 535) - use real .1 package, not transitional .5
apt-get install -y --allow-downgrades libnvidia-compute-470=470.256.02-0ubuntu0.24.04.1 2>&1 | tail -n 20 || true
apt-get install -y --no-install-recommends nvidia-utils-470=470.256.02-0ubuntu0.24.04.1 2>&1 | tail -n 20 || true
# Host driver provides /dev/nvidia* but LXC needs userspace nvidia-smi + libnvidia-ml 470
# The 470 deb on noble leaves a broken symlink /usr/bin/nvidia-smi -> /usr/lib/nvidia-470/bin/nvidia-smi (non-existent)
# and libnvidia-ml.so.1 -> 535. Fix both by using host's binary pushed to /tmp/nvidia-smi
if [ -x /tmp/nvidia-smi ]; then
  rm -f /usr/bin/nvidia-smi
  cp /tmp/nvidia-smi /usr/bin/nvidia-smi
  chmod +x /usr/bin/nvidia-smi
fi
if [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.470.256.02 ]; then
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so
  ldconfig
fi
apt-mark hold libnvidia-compute-535 nvidia-utils-535 2>&1 | head -n 5 || true

# Ensure nvidia libs visible
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
echo 'export PATH=/usr/local/cuda/bin:$PATH' > /etc/profile.d/cuda.sh
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}' >> /etc/profile.d/cuda.sh

# Groups for GPU (nvidia)
usermod -aG render root || true
usermod -aG video root || true

# SSH enable
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
systemctl enable ssh 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# --- Pre-Build Checks ---
echo "[1/7] Verifying CUDA + K80 dual-GPU..."
# Fix nvidia-smi inside LXC (host driver 470.256.02, LXC apt may leave broken symlink to non-existent /usr/lib/nvidia-470/bin/nvidia-smi)
if [ -L /usr/bin/nvidia-smi ] && [ ! -e /usr/bin/nvidia-smi ]; then rm -f /usr/bin/nvidia-smi; fi
if [ ! -x /usr/bin/nvidia-smi ] && [ -x /tmp/nvidia-smi ]; then cp /tmp/nvidia-smi /usr/bin/nvidia-smi; chmod +x /usr/bin/nvidia-smi; fi
if [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.470.256.02 ]; then
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
fi
# Ensure PATH includes CUDA
export PATH=/usr/local/cuda/bin:${PATH:-}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
# Use set +o pipefail for nvidia-smi | head to avoid SIGPIPE with pipefail
set +o pipefail
nvidia-smi -L 2>&1 | head -20 || { echo "ERROR: nvidia-smi failed. Check /dev/nvidia* passthrough (c 195:*, c 511:*)." ; ls -l /dev/nvidia* 2>&1 | head -20; ls -l /usr/bin/nvidia-smi* 2>&1 | head -n 20; exit 1; }
set -o pipefail
echo "  nvidia-smi -L:"
nvidia-smi -L
echo "  Checking both GK210 chips (expect 2 GPUs):"
GPU_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || true)
set +o pipefail
if [ "$GPU_COUNT" -ne 2 ]; then echo "WARNING: Expected 2 K80 GPUs, found $GPU_COUNT" >&2; fi
nvcc --version 2>&1 | head -5 || echo "nvcc not yet in PATH"
echo "  Pinned: CUDA $CUDA_REPO_VERSION + driver $NVIDIA_DRIVER_VERSION (cc $CUDA_ARCH)"

# --- 2. BUILD LLAMA.CPP (CUDA 11.8, cc 3.7) ---
echo "[2/7] Cloning and building llama.cpp (CUDA $CUDA_MAJOR, cc $CUDA_ARCH)..."
# CUDA 11.8 only supports gcc <= 11. Noble default is gcc 13, so install gcc-11 and use it
apt-get install -y gcc-11 g++-11 2>&1 | tail -n 20 || true
export CC=gcc-11
export CXX=g++-11
export CUDAHOSTCXX=g++-11
export CUDAHOSTCC=gcc-11
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 100 2>&1 | head -n 5 || true
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 100 2>&1 | head -n 5 || true
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

# K80 needs CUDA_ARCH 37, no FA (flash attention requires cc 7+), keep cuBLAS
# Use -allow-unsupported-compiler as fallback if gcc-11 not available
cmake -S . -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
  -DGGML_CUDA_FA_ALL_QUANTS=OFF \
  -DGGML_CUDA_FORCE_DMMV=OFF \
  -DGGML_VULKAN=OFF \
  -DGGML_HIP=OFF \
  -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler" \
  -DCMAKE_BUILD_TYPE=Release

echo "[2/7] Building... (this can take 15-30 minutes with 12 cores, CUDA 11.8)"
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
AVAIL_MB=$(( TOTAL_MEM_KB / 1024 - 1024 ))
if [ "$AVAIL_MB" -lt 1500 ]; then JOBS=1
elif [ "$AVAIL_MB" -lt 3000 ]; then JOBS=2
elif [ "$AVAIL_MB" -lt 4500 ]; then JOBS=3
else JOBS=$(nproc)
fi
[ "$JOBS" -gt 12 ] && JOBS=12
echo "[2/7] Detected ${TOTAL_MEM_KB}kB RAM -> using -j${JOBS} (was -j$(nproc)) to avoid OOM"
cmake --build build --config Release -j${JOBS}

# --- 3. MODEL STORAGE & DOWNLOAD ---
echo "[3/7] Setting up model directory..."
mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

ACTIVE_MODEL_FILE=""

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present: $ACTIVE_MODEL_FILE"
else
  PREFERRED_MODELS=(
    "Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf"
    "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
    "Qwen_Qwen3-Coder-Next-Q4_K_M.gguf"
  )
  for MODEL_CANDIDATE in "${PREFERRED_MODELS[@]}"; do
    if [ -f "${MODEL_DIR}/${MODEL_CANDIDATE}" ]; then
      ACTIVE_MODEL_FILE="$MODEL_CANDIDATE"
      echo "Using preferred existing model from mounted storage: $ACTIVE_MODEL_FILE"
      break
    fi
  done

  if [ -z "${ACTIVE_MODEL_FILE}" ]; then
    mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | sort)
    if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
      ACTIVE_MODEL_FILE="${EXISTING_MODELS[0]}"
      echo "Using existing model from mounted storage: $ACTIVE_MODEL_FILE"
    else
      ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
      echo "No existing models found; will use default (download manually if needed): $ACTIVE_MODEL_FILE"
    fi
  fi
fi

# --- 4. SYSTEMD SERVICE ---
echo "[4/7] Creating systemd service for llama-server (CUDA)..."
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - CUDA K80 on port 80 - pinned CUDA $CUDA_REPO_VERSION + driver $NVIDIA_DRIVER_VERSION
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
Environment=PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib
Environment=CUDA_VISIBLE_DEVICES=0,1
ExecStart=${LLAMA_CPP_DIR}/build/bin/llama-server \\
  --model ${MODEL_DIR}/${ACTIVE_MODEL_FILE} \\
  --host 0.0.0.0 --port 80 \\
  --ctx-size 32768 \\
  -ngl 99 \\
  --batch-size 512 \\
  --parallel 1 \\
  --cache-type-k q4_0 \\
  --cache-type-v q4_0
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

# --- 5. MODEL SWITCH SCRIPT (K80 dual GK210 - single source) ---
# Single script: /usr/local/bin/k80-switch-model.sh + /srv/ai/models/k80-switch-model.sh
# Refactored from hlh-ai-engine switch-model.sh v1.7.0, tuned for K80 CUDA 11.8 cc 3.7
# Changes vs upstream: banner/K80 VRAM table (2x12GB=24GB), -ngl 99, --batch-size 512,
# no --device/Vulkan pin (CUDA uses CUDA_VISIBLE_DEVICES=0,1), verify via nvidia-smi.
echo "[5/7] Creating model switcher: $SWITCH_SCRIPT (Tesla K80 dual GK210) -> $SHARED_SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" << 'EOS'
#!/usr/bin/env bash
# k80-switch-model.sh
# Version: 1.7.0-k80
# Description: Interactive model switcher for llama.cpp ai-engine service (Tesla K80 dual GK210)
# Supports: model selection, ctx-size, KV cache quantization, speculative decoding method (MTP draft / ngram / none)
# Refactored from hlh-ai-engine switch-model.sh v1.7.0 for K80 CUDA 11.8 + 470.256.02 cc 3.7
# K80 dual: 2x GK210GL 12GB per chip = 24GB board via OCuLink, split via CUDA_VISIBLE_DEVICES=0,1
# Changelog:
#   1.7.0-k80 - Fork v1.7.0: K80 dual VRAM table (24GB), -ngl 99, --batch-size 512, no --device pin,
#             verify via nvidia-smi, shared copy at /srv/ai/models/k80-switch-model.sh for MI60 reuse
#   1.7.0 - (upstream) Removed DFlash2 support
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

is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}
is_moe_model() {
  [[ "$(basename "$1")" =~ -A[0-9]+B- ]]
}
rewrite_execstart() {
  local model="$1" ctx="$2" kv="$3" spec_flags="$4"
  local tmp_file
  tmp_file="$(mktemp)"
  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"
  awk -v model="$model" -v ctx="$ctx" -v kv="$kv" -v spec_flags="$spec_flags" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*llama-server/ {
      done=1
      print "ExecStart=/opt/llama.cpp/build/bin/llama-server \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 80 \\"
      print "  --ctx-size " ctx " \\"
      print "  -ngl 99 \\"
      print "  --batch-size 512 \\"
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
echo "║              k80-switch-model.sh (Tesla K80 dual GK210)         ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  VRAM BUDGET  K80 dual 2×12GB = 24GB board (split 0,1)           ║"
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
CUR_CUDA_VISIBLE=$(grep -E '^Environment=CUDA_VISIBLE_DEVICES' "$SYSTEMD_SERVICE" | cut -d= -f2- || echo "0,1")
K80_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || echo "?")

echo "  Model directory : $MODEL_DIR"
echo "  Currently active: $CUR_MODEL"
echo "  ctx-size        : ${CUR_CTX:-(not set)}"
echo "  KV cache (K/V)  : ${CUR_KV_K} / ${CUR_KV_V}"
echo "  Spec decode     : $CUR_SPEC"
echo "  CUDA_VISIBLE    : $CUR_CUDA_VISIBLE ($K80_COUNT K80 GPUs)"
echo "  nvidia-smi      :"
nvidia-smi -L 2>&1 | sed 's/^/    /' || echo "    nvidia-smi failed"
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

if is_mtp_model "$NEW_MODEL"; then
  if [ -z "$MTP_DRAFT_N_MAX" ]; then
    if is_moe_model "$NEW_MODEL"; then
      MTP_DRAFT_N_MAX=5
    else
      MTP_DRAFT_N_MAX=3
    fi
  fi
  DEFAULT_SPEC=1
  echo ""
  echo "Speculative decoding method:"
  echo "   1) MTP draft     — use the model's MTP heads (default, n-max $MTP_DRAFT_N_MAX)"
  echo "   2) ngram-mod     — n-gram matching, self-speculative (tunable)"
  echo "   3) ngram-map-k4v — n-gram keys + 4 m-gram values"
  echo "   4) ngram-map-k   — n-gram keys only"
  echo "   5) ngram-simple  — simple n-gram lookup"
  echo "   6) none (standard) — disable speculative decoding"
  read -rp "Select method [default: $DEFAULT_SPEC]: " SPEC_CHOICE
  case "${SPEC_CHOICE:-$DEFAULT_SPEC}" in
    1)
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
    6|*)
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
echo "  KV cache    : $NEW_KV (K and V)"
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

rewrite_execstart "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$SPEC_FLAGS"

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
  echo "  [✓] KV cache    : $NEW_KV (K and V)"
  echo "  [✓] Spec decode : $NEW_METHOD"
  echo "  [✓] Service     : $SERVICE running (health OK)"
  echo ""
  echo "  Web UI ready at       : http://$(hostname -I | awk '{print $1}'):80"
  echo "  Verify GPU usage with  : nvidia-smi"
  echo "  Watch logs with       : journalctl -u $SERVICE -f"
else
  echo "  [✗] WARNING: $SERVICE did not start cleanly after switch!"
  echo "  Check logs with: journalctl -u $SERVICE -f"
  exit 1
fi
EOS
chmod +x "$SWITCH_SCRIPT"
# Shared copy for MI60 reuse (single source)
cp "$SWITCH_SCRIPT" "$SHARED_SWITCH_SCRIPT"
chmod +x "$SHARED_SWITCH_SCRIPT"
# Cleanup stale names — only k80-switch-model.sh should exist per request
rm -f /usr/local/bin/cuda-switch-model.sh /usr/local/bin/egpu-switch-model.sh /usr/local/bin/switch-model.sh 2>/dev/null || true
rm -f "${MODEL_DIR}/cuda-switch-model.sh" "${MODEL_DIR}/egpu-switch-model.sh" "${MODEL_DIR}/switch-model.sh" 2>/dev/null || true

# --- 6. ENABLE & START ---
echo "[6/7] Enabling $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 7. VERIFICATION ---
echo "[7/7] Verifying..."
nvidia-smi 2>&1 | head -20 || true
${LLAMA_CPP_DIR}/build/bin/llama-server --version 2>&1 | head -5 || true
systemctl status "$SERVICE_NAME" --no-pager | head -30
echo ""
echo "[Bootstrap complete - k80 CUDA 11.8 + 470.256.02, cc 3.7 dual-GK210]"
echo "  Web UI: http://<container-ip>:80 (LXC 131 -> 192.168.1.31:80)"
echo "  Switch: k80-switch-model.sh (also /srv/ai/models/k80-switch-model.sh for MI60 reuse)"
echo "  Pinned: CUDA $CUDA_REPO_VERSION + driver $NVIDIA_DRIVER_VERSION"
