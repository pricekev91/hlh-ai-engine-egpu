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
SWITCH_SCRIPT="/usr/local/bin/cuda-switch-model.sh"

# --- 1. BASE DEPENDENCIES + CUDA 11.8 (pinned) ---
echo "[1/7] Installing base dependencies + CUDA $CUDA_REPO_VERSION (pinned)..."
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip bc \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server

# Add NVIDIA CUDA repo for ubuntu2404 (pinned CUDA 11.8)
if [ ! -f /etc/apt/sources.list.d/cuda-ubuntu2404.list ]; then
  echo "  Adding NVIDIA CUDA repo (ubuntu2404, CUDA $CUDA_MAJOR)..."
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg 2>/dev/null || \
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/7fa2af80.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg
  echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64 /" > /etc/apt/sources.list.d/cuda-ubuntu2404.list
  apt-get update
fi

# Install CUDA toolkit 11.8 (pinned) — driver is host-side 470, toolkit is LXC-side
echo "  Installing cuda-toolkit-$CUDA_MAJOR=$CUDA_VERSION (pinned)..."
apt-get install -y --no-install-recommends cuda-toolkit-${CUDA_MAJOR}=${CUDA_VERSION} cuda-drivers-470=470.256.02-1 2>&1 | tail -n 30 || \
apt-get install -y --no-install-recommends cuda-toolkit-${CUDA_MAJOR} 2>&1 | tail -n 30

# Ensure nvidia libs visible
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
echo 'export PATH=/usr/local/cuda/bin:$PATH' > /etc/profile.d/cuda.sh
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh

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
nvidia-smi -L 2>&1 | head -20 || { echo "ERROR: nvidia-smi failed. Check /dev/nvidia* passthrough (c 195:*, c 511:*)." ; ls -l /dev/nvidia* 2>&1 | head -20; exit 1; }
echo "  nvidia-smi -L:"
nvidia-smi -L
echo "  Checking both GK210 chips (expect 2 GPUs):"
GPU_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || true)
if [ "$GPU_COUNT" -ne 2 ]; then echo "WARNING: Expected 2 K80 GPUs, found $GPU_COUNT" >&2; fi
nvcc --version 2>&1 | head -5 || echo "nvcc not yet in PATH"
echo "  Pinned: CUDA $CUDA_REPO_VERSION + driver $NVIDIA_DRIVER_VERSION (cc $CUDA_ARCH)"

# --- 2. BUILD LLAMA.CPP (CUDA 11.8, cc 3.7) ---
echo "[2/7] Cloning and building llama.cpp (CUDA $CUDA_MAJOR, cc $CUDA_ARCH)..."
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

# K80 needs CUDA_ARCH 37, no FA (flash attention requires cc 7+), keep cuBLAS
cmake -S . -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
  -DGGML_CUDA_FA_ALL_QUANTS=OFF \
  -DGGML_CUDA_FORCE_DMMV=OFF \
  -DGGML_VULKAN=OFF \
  -DGGML_HIP=OFF \
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

# --- 5. MODEL SWITCH SCRIPT (CUDA) ---
echo "[5/7] Creating model switcher: $SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" << 'EOS'
#!/usr/bin/env bash
# cuda-switch-model.sh
# Version: 1.0.0-k80
# Description: Model switcher for K80 CUDA (cc 3.7) - pinned CUDA 11.8 + 470
set -euo pipefail
MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
is_mtp_model() { [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]; }
rewrite_execstart() {
  local model="$1" ctx="$2" kv="$3" spec_flags="$4"
  local tmp=$(mktemp)
  cp "$SYSTEMD_SERVICE" "${SYSTEMD_SERVICE}.backup.$(date +%s)"
  awk -v model="$model" -v ctx="$ctx" -v kv="$kv" -v spec="$spec_flags" '
    BEGIN { in_block=0; done=0 }
    /^ExecStart=.*llama-server/ && !in_block {
      done=1
      print "ExecStart=/opt/llama.cpp/build/bin/llama-server \\"
      print "  --model " model " \\"
      print "  --host 0.0.0.0 --port 80 \\"
      print "  --ctx-size " ctx " \\"
      print "  -ngl 99 \\"
      print "  --batch-size 512 \\"
      print "  --cache-type-k " kv " \\"
      if (spec != "") {
        print "  --cache-type-v " kv " \\"
        print "  " spec " \\"
        print "  --parallel 1"
      } else {
        print "  --cache-type-v " kv " \\"
        print "  --parallel 1"
      }
      in_block=1; next
    }
    in_block { if (/\\$/) next; if (/^Restart=/) { in_block=0; print; next } next }
    { print }
    END { if (!done) exit 42 }
  ' "$SYSTEMD_SERVICE" > "$tmp" || { rm -f "$tmp"; echo "rewrite failed" >&2; exit 1; }
  mv "$tmp" "$SYSTEMD_SERVICE"
}
CUR_MODEL=$(grep -- '--model ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--model") print $(i+1)}')
CUR_CTX=$(grep -- '--ctx-size ' "$SYSTEMD_SERVICE" | awk '{for(i=1;i<=NF;i++) if ($i=="--ctx-size") print $(i+1)}')
echo "Current: $CUR_MODEL ctx $CUR_CTX"
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
printf "Available:\n"; for i in "${!MODELS[@]}"; do printf " %2d) %s\n" $((i+1)) "${MODELS[$i]}"; done
read -rp "Select model: " CHOICE
NEW_MODEL="${MODELS[$((CHOICE-1))]}"
read -rp "ctx-size [32768]: " NEW_CTX; NEW_CTX=${NEW_CTX:-32768}
read -rp "KV quant [q4_0]: " NEW_KV; NEW_KV=${NEW_KV:-q4_0}
if is_mtp_model "$NEW_MODEL"; then SPEC="--spec-type draft-mtp --spec-draft-n-max 3"; else read -rp "spec_flags (empty for none): " SPEC; fi
rewrite_execstart "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$SPEC"
systemctl daemon-reload; systemctl restart "$SERVICE"
systemctl status "$SERVICE" --no-pager | head -20
EOS
chmod +x "$SWITCH_SCRIPT"

# --- 5b. K80 helper ---
K80_HELPER="/usr/local/bin/k80-switch-model.sh"
cat > "$K80_HELPER" << 'EOS_K80'
#!/usr/bin/env bash
# k80-switch-model.sh - show K80 dual status + switch
set -euo pipefail
echo "K80 dual GK210 status (pinned CUDA 11.8 + 470.256.02):"
nvidia-smi -L 2>&1 | head -10 || echo "nvidia-smi failed"
nvidia-smi 2>&1 | head -30 || true
echo ""
echo "llama.cpp devices:"
/opt/llama.cpp/build/bin/llama-server --list-devices 2>&1 | head -20 || true
EOS_K80
chmod +x "$K80_HELPER"
cp "$SWITCH_SCRIPT" "${MODEL_DIR}/cuda-switch-model.sh" 2>/dev/null || true
cp "$K80_HELPER" "${MODEL_DIR}/k80-switch-model.sh" 2>/dev/null || true

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
echo "  Switch: cuda-switch-model.sh"
echo "  K80 helper: k80-switch-model.sh (shows both chips)"
echo "  Pinned: CUDA $CUDA_REPO_VERSION + driver $NVIDIA_DRIVER_VERSION"
