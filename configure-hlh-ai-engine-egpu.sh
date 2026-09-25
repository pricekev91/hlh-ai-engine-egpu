#!/usr/bin/env bash
set -euo pipefail

# configure-hlh-ai-engine-egpu.sh - 2nd script (configuration) for hlh-ai-engine-egpu
# Pure bash, no ansible/opentofu. One for provision (deploy), one for configuration.
# Usage:
#   ./configure-hlh-ai-engine-egpu.sh [--host <ip>] [--via-ssh]          # host-side: pushes and runs bootstrap inside LXC
#   ./configure-hlh-ai-engine-egpu.sh --bootstrap-inside                 # inside LXC: runs the actual bootstrap (called via pct exec)
# When invoked via pct exec or ssh, the bootstrap logic runs inside the target LXC.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_ID=111
DEFAULT_HOST="192.168.1.11"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HOST_OVERRIDE=""
VIA_SSH=false
BOOTSTRAP_INSIDE=false

usage() {
	cat <<'EOF'
Usage:
	./configure-hlh-ai-engine-egpu.sh [--host <ip>] [--via-ssh]
	./configure-hlh-ai-engine-egpu.sh --bootstrap-inside   (run inside LXC)

Options:
  --host <ip>          Override target host (default 192.168.1.11 or LXC 111 via pct if local)
  --via-ssh            Force ssh even if pct is available
  --bootstrap-inside   Run bootstrap logic inside LXC (invoked via pct exec, not manually)
  -h, --help           Show this help.

Two scripts only: deploy (provision) + configure (this file). This file *is* the bootstrap when --bootstrap-inside is used.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--host)
			[[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
			HOST_OVERRIDE="$2"; shift ;;
		--via-ssh) VIA_SSH=true ;;
		--bootstrap-inside) BOOTSTRAP_INSIDE=true ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
	shift
done

if $BOOTSTRAP_INSIDE; then
	# --- BEGIN BOOTSTRAP LOGIC (formerly configure-ai-engine-inside-lxc.sh) ---
# configure-ai-engine-inside-lxc.sh
# Version: 1.0.1-egpu-cuda (fix: stale CUDA list without key broke every apt-get update; curl/gpg missing on minimal template; jammy pin deleted after creation)
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with CUDA for Tesla V100 (GV100 32GB cc 7.0) via OCuLink
# Target GPU: NVIDIA Tesla V100 GV100GL PG500-216 (32GB HBM2) single via OCuLink c5:00.0 on Proxmox 9.x privileged LXC
# Backend: GGML_CUDA=ON arch 70, FA ON, CUDA 12.4 + driver 550.163.01 (last stable for Volta in Debian trixie; R580 last overall)
# Requirements: Run as root inside privileged LXC with /dev/nvidia0 passthrough and /srv/ai/models bind mount

set -euo pipefail

# --- PINNED VERSIONS (V100 Volta cc 7.0) ---
# Host driver: R580 580.65.06 on 6.14.11-9-pve (validated LTS for Volta), 550 on 6.5.
# 470 only for legacy 6.5/7.0 where 580 not available, but UVM broken on >=6.15.
# LXC CUDA must match host driver: 470->11.8, 550->12.4, 580->12.8. Auto-detect via uname.
KERNEL_VER=$(uname -r)
KERNEL_MAJ=$(echo "$KERNEL_VER" | cut -d. -f1)
if [[ "$KERNEL_VER" == *6.14* ]] || [[ "$KERNEL_MAJ" -ge 7 ]]; then
  NVIDIA_DRIVER_VERSION="580.65.06"
  CUDA_VERSION="12.8.0-1"
  CUDA_MAJOR="12.8"
  CUDA_REPO="ubuntu2404"
elif [[ "$KERNEL_MAJ" -ge 6 ]]; then
  # 6.5 fallback
  NVIDIA_DRIVER_VERSION="550.163.01"
  CUDA_VERSION="12.4.1"
  CUDA_MAJOR="12.4"
  CUDA_REPO="ubuntu2404"
else
  NVIDIA_DRIVER_VERSION="550.163.01"
  CUDA_VERSION="12.4.1"
  CUDA_MAJOR="12.4"
  CUDA_REPO="ubuntu2404"
fi
# R580 (580.65.06) is last driver supporting Volta - CUDA 12.8 is final sm70 offline compile.

# --- CONFIGURABLE ---
MODEL_DIR="/srv/ai/models"
DEFAULT_MODEL_FILE="Qwen3.8-27B-MTP-Q4_K_M.gguf"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_CPP_DIR="/opt/llama.cpp"
SERVICE_NAME="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SWITCH_SCRIPT="/usr/local/bin/egpu-switch-model.sh"
SHARED_SWITCH_SCRIPT="${MODEL_DIR}/egpu-switch-model.sh"

# --- 1. BASE DEPENDENCIES + CUDA TOOLKIT ---
echo "[1/7] Installing base dependencies + CUDA $CUDA_MAJOR + driver ${NVIDIA_DRIVER_VERSION} userspace..."
export DEBIAN_FRONTEND=noninteractive
export LANG=C LC_ALL=C
# Repair stale broken CUDA repo (list without key) from a previous failed run.
# A list file without its keyring makes EVERY apt-get update fail (E: not signed)
# and with set -e aborts the bootstrap before curl/gpg are even installed.
if [ -f /etc/apt/sources.list.d/cuda-ubuntu2404.list ] && [ ! -s /usr/share/keyrings/cuda-ubuntu2404.gpg ]; then
  echo "  Removing stale cuda-ubuntu2404.list (missing keyring)..."
  rm -f /etc/apt/sources.list.d/cuda-ubuntu2404.list
fi
if [ -f /etc/apt/sources.list.d/cuda-ubuntu2204.list ] && [ ! -s /usr/share/keyrings/cuda-ubuntu2204.gpg ]; then
  echo "  Removing stale cuda-ubuntu2204.list (missing keyring)..."
  rm -f /etc/apt/sources.list.d/cuda-ubuntu2204.list
fi
apt_retry() {
  local n=1 max=3
  while [ $n -le $max ]; do
    if apt-get update 2>&1 | tail -n 10; then return 0; fi
    echo "  WARNING: apt-get update failed (attempt $n/$max), retrying..." >&2
    sleep 5; n=$((n+1))
  done
  echo "ERROR: apt-get update failed after $max attempts" >&2
  return 1
}
fetch_key() {
  # $1=url $2=dest — curl preferred, wget fallback (minimal LXC has no curl/gpg yet)
  local url="$1" dest="$2" tmp_pub
  tmp_pub="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$tmp_pub" || { rm -f "$tmp_pub"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp_pub" "$url" || { rm -f "$tmp_pub"; return 1; }
  else
    echo "ERROR: neither curl nor wget available to fetch $url" >&2
    rm -f "$tmp_pub"; return 1
  fi
  [ -s "$tmp_pub" ] || { echo "ERROR: downloaded key is empty: $url" >&2; rm -f "$tmp_pub"; return 1; }
  if command -v gpg >/dev/null 2>&1; then
    gpg --dearmor -o "$dest" "$tmp_pub" || { rm -f "$tmp_pub"; return 1; }
  else
    # No gpg yet — key is ASCII; store dearmored later after gnupg install.
    # For now keep ASCII and convert after base install.
    cp "$tmp_pub" "${dest}.asc" || { rm -f "$tmp_pub"; return 1; }
  fi
  rm -f "$tmp_pub"
}
if ! locale -a 2>&1 | grep -qi "en_US.utf8"; then
  apt_retry && apt-get install -y locales 2>&1 | tail -n 5 || true
  locale-gen en_US.UTF-8 2>&1 | tail -n 5 || true
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>&1 | tail -n 5 || true
fi
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
# Base tools FIRST (from Ubuntu archives only — CUDA repo not added yet),
# so curl/gpg exist before any CUDA key download.
apt_retry
apt-get install -y --no-install-recommends \
  ca-certificates wget curl gnupg \
  build-essential git cmake pkg-config \
  python3 python3-pip unzip bc \
  libopenblas-dev libssl-dev \
  openssh-server
# If key was fetched as ASCII (no gpg at fetch time), dearmor it now.
for f in /usr/share/keyrings/cuda-*.asc; do
  [ -f "$f" ] || continue
  gpg --dearmor -o "${f%.asc}.gpg" "$f" && rm -f "$f" || true
done

# Add NVIDIA CUDA repo matching host driver branch (key verified BEFORE list written)
if [[ "$CUDA_REPO" == "ubuntu2204" ]]; then
  if [ ! -s /usr/share/keyrings/cuda-ubuntu2204.gpg ]; then
    echo "  Adding CUDA ubuntu2204 repo for toolkit $CUDA_MAJOR (470 branch)..."
    rm -f /etc/apt/sources.list.d/cuda-ubuntu2204.list
    fetch_key "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub" "/usr/share/keyrings/cuda-ubuntu2204.gpg" || { echo "ERROR: Failed to fetch CUDA ubuntu2204 key after 3 attempts: Connection error." >&2; exit 1; }
    echo "deb [signed-by=/usr/share/keyrings/cuda-ubuntu2204.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64 /" > /etc/apt/sources.list.d/cuda-ubuntu2204.list
    apt_retry || { echo "ERROR: apt-get update failed after adding CUDA repo" >&2; exit 1; }
  fi
  # jammy libtinfo5 needed for 11.8 on noble
  if ! grep -q "jammy" /etc/apt/sources.list.d/* 2>/dev/null; then
    echo "deb http://archive.ubuntu.com/ubuntu jammy main universe" > /etc/apt/sources.list.d/jammy-libtinfo5.list
    cat > /etc/apt/preferences.d/jammy-libtinfo5-pin <<'PIN'
Package: libtinfo5 libncurses5
Pin: release n=jammy
Pin-Priority: 100
PIN
    apt_retry || true
  fi
else
  if [ ! -s /usr/share/keyrings/cuda-ubuntu2404.gpg ]; then
    echo "  Adding CUDA ubuntu2404 repo for toolkit $CUDA_MAJOR..."
    rm -f /etc/apt/sources.list.d/cuda-ubuntu2404.list
    fetch_key "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub" "/usr/share/keyrings/cuda-ubuntu2404.gpg" || { echo "ERROR: Failed to fetch CUDA ubuntu2404 key after 3 attempts: Connection error." >&2; exit 1; }
    echo "deb [signed-by=/usr/share/keyrings/cuda-ubuntu2404.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64 /" > /etc/apt/sources.list.d/cuda-ubuntu2404.list
    apt_retry || { echo "ERROR: apt-get update failed after adding CUDA repo" >&2; exit 1; }
  fi
fi

# Clean stale repos/pins from the OTHER branch only (never delete the pin just created above)
if [[ "$CUDA_REPO" == "ubuntu2404" ]]; then rm -f /etc/apt/sources.list.d/cuda-ubuntu2204.list /etc/apt/sources.list.d/jammy-libtinfo5.list 2>/dev/null || true; fi

# Userspace driver must match host for nvidia-smi (V100 Volta)
apt_retry
if [[ "$CUDA_MAJOR" == "11.8" ]]; then
  echo "  Installing CUDA toolkit $CUDA_MAJOR + nvidia userspace $NVIDIA_DRIVER_VERSION (470 branch)..."
  apt-get install -y --no-install-recommends libtinfo5 2>&1 | tail -n 10 || true
  apt-get install -y --allow-downgrades cuda-toolkit-11-8 2>&1 | tail -n 30 || apt-get install -y cuda-toolkit 2>&1 | tail -n 20 || true
  apt-get install -y --allow-downgrades libnvidia-compute-470=${NVIDIA_DRIVER_VERSION}-0ubuntu0.24.04.1 2>&1 | tail -n 20 || apt-get install -y --allow-downgrades libnvidia-compute-470 2>&1 | tail -n 20 || true
  apt-get install -y --no-install-recommends nvidia-utils-470=${NVIDIA_DRIVER_VERSION}-0ubuntu0.24.04.1 2>&1 | tail -n 20 || apt-get install -y --no-install-recommends nvidia-utils-470 2>&1 | tail -n 20 || true
  apt-mark hold libnvidia-compute-470 nvidia-utils-470 cuda-toolkit-11-8 2>&1 | head -n 5 || true
  DRIVER_PKG="470"
elif [[ "$CUDA_MAJOR" == "12.8" ]]; then
  echo "  Installing CUDA toolkit $CUDA_MAJOR + nvidia userspace $NVIDIA_DRIVER_VERSION (580 branch)..."
  apt-get install -y --allow-downgrades cuda-toolkit-12-8 2>&1 | tail -n 30 || apt-get install -y cuda-toolkit 2>&1 | tail -n 20 || true
  apt-mark unhold libnvidia-compute-580 nvidia-utils-580 2>/dev/null || true
  apt-get install -y --allow-downgrades libnvidia-compute-580=${NVIDIA_DRIVER_VERSION}-0ubuntu1 2>&1 | tail -n 20 || apt-get install -y --allow-downgrades libnvidia-compute-580 2>&1 | tail -n 20 || true
  apt-get install -y --no-install-recommends nvidia-utils-580=${NVIDIA_DRIVER_VERSION}-0ubuntu1 2>&1 | tail -n 20 || apt-get install -y --no-install-recommends nvidia-utils-580 2>&1 | tail -n 20 || true
  # Fallback if 580 not in repo (Tesla .run host) - try generic 580
  if ! dpkg -l | grep -q libnvidia-compute-580; then
    echo "  WARNING: libnvidia-compute-580 not in repo, trying nvidia-utils-580 generic"
    apt-get install -y --allow-downgrades libnvidia-compute-580 nvidia-utils-580 2>&1 | tail -n 20 || true
  fi
  apt-mark hold libnvidia-compute-580 nvidia-utils-580 cuda-toolkit-12-8 2>&1 | head -n 5 || true
  # NVML requires userspace to EXACTLY match the host kernel driver. NVIDIA rotates
  # 580-branch point releases, so an unpinned fallback can install a mismatched
  # version and silently break the GPU (Driver/library version mismatch).
  _installed_580="$(dpkg-query -W -f='${Version}' libnvidia-compute-580 2>/dev/null || true)"
  if [[ -n "$_installed_580" && "$_installed_580" != "${NVIDIA_DRIVER_VERSION}-"* ]]; then
    echo "  FATAL: libnvidia-compute-580 ${_installed_580} != host driver ${NVIDIA_DRIVER_VERSION} (NVML needs exact match)." >&2
    echo "         Fix: apt-mark unhold libnvidia-compute-580 nvidia-utils-580 && re-run, or upgrade the host driver to the current 580 tip." >&2
    exit 1
  fi
  DRIVER_PKG="580"
else
  echo "  Installing CUDA toolkit $CUDA_MAJOR + nvidia userspace $NVIDIA_DRIVER_VERSION..."
  apt-get install -y --allow-downgrades cuda-toolkit-12-4 2>&1 | tail -n 30 || apt-get install -y cuda-toolkit 2>&1 | tail -n 20 || true
  apt-get install -y --allow-downgrades libnvidia-compute-550=${NVIDIA_DRIVER_VERSION}-0ubuntu1 2>&1 | tail -n 20 || apt-get install -y --allow-downgrades libnvidia-compute-550 2>&1 | tail -n 20 || true
  apt-get install -y --no-install-recommends nvidia-utils-550=${NVIDIA_DRIVER_VERSION}-0ubuntu1 2>&1 | tail -n 20 || apt-get install -y --no-install-recommends nvidia-utils-550 2>&1 | tail -n 20 || true
  apt-mark hold libnvidia-compute-550 nvidia-utils-550 cuda-toolkit-12-4 2>&1 | head -n 5 || true
  DRIVER_PKG="550"
fi
# nvtop for live GPU monitoring
apt-get install -y --no-install-recommends nvtop 2>&1 | tail -n 10 || echo "WARNING: nvtop not in repo, skipping" >&2

# Host driver provides /dev/nvidia* but LXC needs userspace nvidia-smi + libnvidia-ml
if [ -x /tmp/nvidia-smi ]; then
  rm -f /usr/bin/nvidia-smi
  cp /tmp/nvidia-smi /usr/bin/nvidia-smi
  chmod +x /usr/bin/nvidia-smi
fi
if [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} ]; then
  ln -sf libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ln -sf libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} /usr/lib/x86_64-linux-gnu/libnvidia-ml.so 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
elif [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.65.06 ]; then
  ln -sf libnvidia-ml.so.580.65.06 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ln -sf libnvidia-ml.so.580.65.06 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
elif [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.550.163.01 ]; then
  ln -sf libnvidia-ml.so.550.163.01 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
elif [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.470.256.02 ]; then
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
fi

# Env for CUDA
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
echo 'export PATH=/usr/local/cuda/bin:$PATH' > /etc/profile.d/cuda.sh
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh
if [ -f /usr/local/cuda-12.8/targets/x86_64-linux/lib/libcudart.so.12 ]; then ln -sf /usr/local/cuda-12.8 /usr/local/cuda 2>/dev/null || true; fi
if [ -f /usr/local/cuda-12.4/targets/x86_64-linux/lib/libcudart.so.12 ]; then ln -sf /usr/local/cuda-12.4 /usr/local/cuda 2>/dev/null || true; fi
if [ -f /usr/local/cuda-11.8/targets/x86_64-linux/lib/libcudart.so.11.0 ]; then ln -sf /usr/local/cuda-11.8 /usr/local/cuda 2>/dev/null || true; fi
ldconfig

# Groups for GPU
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
echo "[1/7] Verifying CUDA + V100 single-GPU (nvidia-smi)..."
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
if [ -L /usr/bin/nvidia-smi ] && [ ! -e /usr/bin/nvidia-smi ]; then rm -f /usr/bin/nvidia-smi; fi
if [ ! -x /usr/bin/nvidia-smi ] && [ -x /tmp/nvidia-smi ]; then cp /tmp/nvidia-smi /usr/bin/nvidia-smi; chmod +x /usr/bin/nvidia-smi; fi
if [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} ]; then
  ln -sf libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ln -sf libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} /usr/lib/x86_64-linux-gnu/libnvidia-ml.so 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
fi
set +o pipefail
nvidia-smi -L 2>&1 | head -20 || {
  echo "WARNING: nvidia-smi failed (host driver not talking to V100 0000:c5:00.0). Host fix needed:" >&2
  echo "  prox01: dkms status | grep nvidia; modinfo nvidia | head; dmesg | grep -i nvidia | tail -n 30" >&2
  ls -l /dev/nvidia* 2>&1 | head -20
}
set -o pipefail
echo "  nvidia-smi -L:"
nvidia-smi -L 2>&1 | head -n 20 || true
echo "  Checking single GV100 chip (expect 1 GPU):"
GPU_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || true)
if [ "$GPU_COUNT" -ne 1 ]; then echo "WARNING: Expected 1 V100 GPU, found $GPU_COUNT" >&2; fi
echo "  Pinned: CUDA $CUDA_MAJOR + driver $NVIDIA_DRIVER_VERSION (Volta cc 7.0, FA ON)"
nvcc --version 2>&1 | head -n 20 || echo "nvcc not found - check cuda-toolkit install"
echo "  CUDA devices:"
nvidia-smi 2>&1 | head -n 30 || true

# --- 2. BUILD LLAMA.CPP (CUDA) ---
echo "[2/7] Cloning and building llama.cpp (CUDA arch 70)..."
# CUDA needs gcc compatible - noble gcc 13 ok for 12.4, but ensure
command -v nvcc >/dev/null 2>&1 || { echo "ERROR: nvcc not found for CUDA build" >&2; exit 1; }
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

cmake -S . -B build \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_VULKAN=OFF \
  -DGGML_HIP=OFF \
  -DGGML_CUDA_FORCE_DMMV=ON \
  -DGGML_CUDA_FORCE_MMQ=ON \
  -DCMAKE_CUDA_ARCHITECTURES=70 \
  -DCMAKE_BUILD_TYPE=Release

echo "[2/7] Building... (15-30 min with 12 cores, CUDA 12.4 sm70)"
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
AVAIL_MB=$(( TOTAL_MEM_KB / 1024 - 1024 ))
if [ "$AVAIL_MB" -lt 1500 ]; then JOBS=1
elif [ "$AVAIL_MB" -lt 3000 ]; then JOBS=2
elif [ "$AVAIL_MB" -lt 4500 ]; then JOBS=3
else JOBS=$(nproc)
fi
[ "$JOBS" -gt 12 ] && JOBS=12
echo "[2/7] Detected ${TOTAL_MEM_KB}kB RAM -> using -j${JOBS}"
cmake --build build --config Release -j${JOBS}

# --- 3. MODEL STORAGE (bind mount — same path host and CT) ---
echo "[3/7] Setting up model directory (bind mount host == CT: $MODEL_DIR)..."
mkdir -p "$MODEL_DIR"
mount | grep -E "on ${MODEL_DIR} " | head -3 || echo "  (no mount yet — may be bind from host)"
ls -lh "$MODEL_DIR" | head -20 || true
cd "$MODEL_DIR"

ACTIVE_MODEL_FILE=""

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present on shared mount: $ACTIVE_MODEL_FILE"
else
  PREFERRED_MODELS=(
    "Qwen3.8-27B-MTP-Q4_K_M.gguf"
    "Qwen3.6-35B-A3B-MTP-Q4_K_M.gguf"
    "Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf"
  )
  for MODEL_CANDIDATE in "${PREFERRED_MODELS[@]}"; do
    if [ -f "${MODEL_DIR}/${MODEL_CANDIDATE}" ]; then
      ACTIVE_MODEL_FILE="$MODEL_CANDIDATE"
      echo "Using preferred existing model from shared mount: $ACTIVE_MODEL_FILE"
      break
    fi
  done

  if [ -z "${ACTIVE_MODEL_FILE}" ]; then
    mapfile -t EXISTING_MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' | sort)
    if [ "${#EXISTING_MODELS[@]}" -gt 0 ]; then
      ACTIVE_MODEL_FILE="${EXISTING_MODELS[0]}"
      echo "Using existing model from shared mount: $ACTIVE_MODEL_FILE"
    else
      ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
      echo "WARNING: No .gguf found on shared mount $MODEL_DIR — service will point to $ACTIVE_MODEL_FILE (populate host RaidZ1-6TB/ai/models first)" >&2
      ls -R "$MODEL_DIR" 2>&1 | head -20 || true
    fi
  fi
fi

if [ ! -f "${MODEL_DIR}/${ACTIVE_MODEL_FILE}" ]; then
  echo "WARNING: Active model file not found: ${MODEL_DIR}/${ACTIVE_MODEL_FILE} — ai-engine will fail to start until host populates /srv/ai/models" >&2
fi

# --- 4. SYSTEMD SERVICE ---
# Default for Qwen3.8-27B-MTP: 128K q4 FA ON MTP draft 3 (17106773984 17GB, 128K ~16GB KV q4_0)
# MTP enabled, 128K as requested (tight on 32GB - may spill to ~33GB)
if [[ "$ACTIVE_MODEL_FILE" == *MTP* ]]; then
  ACTIVE_CTX="131072"
  ACTIVE_SPEC="--spec-type draft-mtp --spec-draft-n-max 3"
else
  ACTIVE_CTX="32768"
  ACTIVE_SPEC=""
fi
# Force 128K for Qwen3.8-27B-MTP as requested
if [[ "$ACTIVE_MODEL_FILE" == "Qwen3.8-27B-MTP-Q4_K_M.gguf" ]]; then
  ACTIVE_CTX="131072"
  ACTIVE_SPEC="--spec-type draft-mtp --spec-draft-n-max 3"
fi
echo "[4/7] Creating systemd service for llama-server (CUDA V100)..."
if [ -n "$ACTIVE_SPEC" ]; then
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - CUDA V100 32GB on port 80 - driver $NVIDIA_DRIVER_VERSION sm70 FA ON MTP 128K q4
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=${LLAMA_CPP_DIR}/build/bin/llama-server \\
  --model ${MODEL_DIR}/${ACTIVE_MODEL_FILE} \\
  --host 0.0.0.0 --port 80 \\
  --ctx-size ${ACTIVE_CTX} \\
  -ngl 99 \\
  --batch-size 512 \\
  --flash-attn on \\
  --cache-type-k q4_0 \\
  --cache-type-v q4_0 \\
  ${ACTIVE_SPEC} \\
  --parallel 1
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT
else
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - CUDA V100 32GB on port 80 - driver $NVIDIA_DRIVER_VERSION sm70 FA ON
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=${LLAMA_CPP_DIR}/build/bin/llama-server \\
  --model ${MODEL_DIR}/${ACTIVE_MODEL_FILE} \\
  --host 0.0.0.0 --port 80 \\
  --ctx-size ${ACTIVE_CTX} \\
  -ngl 99 \\
  --batch-size 512 \\
  --flash-attn on \\
  --cache-type-k q4_0 \\
  --cache-type-v q4_0 \\
  --parallel 1
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT
fi

# --- 5. MODEL SWITCH SCRIPT (V100 GV100 single 32GB) ---
echo "[5/7] Creating model switcher: $SWITCH_SCRIPT (Tesla V100 32GB CUDA) -> $SHARED_SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" << 'EOS'
#!/usr/bin/env bash
# egpu-switch-model.sh
# Version: 1.0.0-v100-cuda
# Description: Interactive model switcher for llama.cpp ai-engine service (Tesla V100 GV100 32GB CUDA)
set -euo pipefail

MODEL_DIR="/srv/ai/models"
SERVICE="ai-engine"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE}.service"
MTP_DRAFT_N_MAX="${MTP_DRAFT_N_MAX:-}"
NGRAM_N_MATCH="${NGRAM_N_MATCH:-24}"
NGRAM_N_MIN="${NGRAM_N_MIN:-48}"
NGRAM_N_MAX="${NGRAM_N_MAX:-64}"
DFLASH_DRAFT_N_MAX="${DFLASH_DRAFT_N_MAX:-7}"

is_mtp_model() { [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]; }
is_dflash_model() { [[ "$(basename "$1")" =~ [Dd][Ff]lash ]]; }
model_family() {
  local base; base="$(basename "$1")"; base="${base%.gguf}"; base="${base%%-[Qq][0-9]*}" ; base="${base%%-[Ii][Qq]*}" ; base="${base%%-[Uu][Dd]*}" ; base="${base%%-[Dd][Ff]lash*}" ; echo "$base"
}
is_moe_model() { [[ "$(basename "$1")" =~ -A[0-9]+B- ]]; }
rewrite_execstart() {
  local model="$1" ctx="$2" kv="$3" spec_flags="$4" ngl="$5"
  local tmp_file; tmp_file="$(mktemp)"
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
      in_block=1; next
    }
    in_block { if (/^Restart=/) { in_block=0; print } next }
    { print }
    END { if (!done) exit 42 }
  ' "$SYSTEMD_SERVICE" > "$tmp_file" || { rm -f "$tmp_file"; echo "ERROR: Failed to rewrite ExecStart" >&2; exit 1; }
  mv "$tmp_file" "$SYSTEMD_SERVICE"
  echo "INFO: Successfully updated service configuration"
}

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        egpu-switch-model.sh (Tesla V100 GV100 32GB CUDA)        ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  BACKEND  CUDA sm70 (FA ON)  32GB HBM2 single GPU 0000:c5:00.0  ║"
echo "║  VRAM BUDGET  32GB single - much larger than K80 2x12GB        ║"
echo "║  Model Weights + KV cache = total (KV scales with ctx)          ║"
echo "║    70B Q4_K_M    ~39 GB   70B Q5_K_M   ~48 GB (needs spill)     ║"
echo "║    35B Q4_K_M    ~21 GB   35B Q5_K_M   ~25 GB -> fits 32GB      ║"
echo "║    30B Q4_K_M    ~18 GB   32B Q4       ~18-22GB                 ║"
echo "║                  KV q4_0    KV q6_0    KV q8_0  (per 32GB)      ║"
echo "║    64K context   ~ 8 GB     ~12 GB     ~18 GB  -> fits 30B Q4   ║"
echo "║    32K context   ~ 4 GB      ~ 6 GB     ~ 9 GB  -> fits 35B Q4  ║"
echo "║    16K context   ~ 2 GB      ~ 3 GB     ~ 5 GB                  ║"
echo "║  V100 supports FA ON for speed + memory efficiency              ║"
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
V100_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || echo "?")

echo "  Model directory : $MODEL_DIR"
echo "  Currently active: $CUR_MODEL"
echo "  ctx-size        : ${CUR_CTX:-(not set)}"
echo "  KV cache (K/V)  : ${CUR_KV_K} / ${CUR_KV_V}"
echo "  Spec decode     : $CUR_SPEC"
echo "  Draft model     : ${CUR_DRAFT:-none}"
echo "  -ngl (GPU layers): ${CUR_NGL:-(not set)}"
echo "  Flash Attention : $CUR_FLASH"
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
echo "   1) 98304  (96K)  — maximum (12GB KV q4_0)"
echo "   2) 73728  (72K)  — extended"
echo "   3) 65536  (64K)  — full (8GB KV q4_0)"
echo "   4) 32768  (32K)  — recommended for 30-35B Q4 on V100 32GB"
echo "   5) 16384  (16K)  — quarter"
echo "   6)  8192   (8K)  — minimal"
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
    if ! [[ "$NEW_CTX" =~ ^[0-9]+$ ]]; then echo "Invalid ctx-size."; exit 1; fi ;;
  *) NEW_CTX=32768 ;;
esac

echo ""
echo "KV cache quantization:"
echo "   1) q8_0  — highest quality, ~2x VRAM vs q4"
echo "   2) q6_0  — very good quality, ~1.5x VRAM vs q4"
echo "   3) q4_0  — recommended for 32GB, lowest VRAM"
echo ""
echo "   Recommendation for V100 32GB 32K: q4_0 or q6_0"

read -rp "Select KV cache quant [default: q4_0]: " KV_CHOICE
case "${KV_CHOICE:-3}" in
  1) NEW_KV="q8_0" ;;
  2) NEW_KV="q6_0" ;;
  3) NEW_KV="q4_0" ;;
  *) NEW_KV="q4_0" ;;
esac

echo ""
echo "GPU layers (-ngl):"
echo "   1) 99  — full GPU offload (default)"
echo "   2) 75  — high"
echo "   3) 50  — balanced"
echo "   4) 25  — low"
echo "   5) Custom — enter manually (0-99)"

read -rp "Select -ngl [default: 99]: " NGL_CHOICE
case "${NGL_CHOICE:-1}" in
  1) NEW_NGL=99 ;;
  2) NEW_NGL=75 ;;
  3) NEW_NGL=50 ;;
  4) NEW_NGL=25 ;;
  5)
    read -rp "Enter custom -ngl value [0-99]: " NEW_NGL
    if ! [[ "$NEW_NGL" =~ ^[0-9]+$ ]] || (( NEW_NGL < 0 || NEW_NGL > 99 )); then echo "Invalid -ngl value."; exit 1; fi ;;
  *) NEW_NGL=99 ;;
esac

if is_mtp_model "$NEW_MODEL" || [ -n "$DFLASH_DRAFT" ]; then
  if is_mtp_model "$NEW_MODEL"; then
    if [ -z "$MTP_DRAFT_N_MAX" ]; then
      if is_moe_model "$NEW_MODEL"; then MTP_DRAFT_N_MAX=5; else MTP_DRAFT_N_MAX=3; fi
    fi
    DEFAULT_SPEC=1
  elif [ -n "$DFLASH_DRAFT" ]; then DEFAULT_SPEC=6; fi
  echo ""
  echo "Speculative decoding method:"
  if is_mtp_model "$NEW_MODEL"; then
    echo "   1) MTP draft     — use the model's MTP heads (default, n-max $MTP_DRAFT_N_MAX) [CUDA sm70 limited - test]"
  else
    echo "   1) MTP draft     — (not available: model is not an MTP model)"
  fi
  echo "   2) ngram-mod     — n-gram matching"
  echo "   3) ngram-map-k4v — n-gram keys + 4 m-gram values"
  echo "   4) ngram-map-k   — n-gram keys only"
  echo "   5) ngram-simple  — simple n-gram lookup"
  if [ -n "$DFLASH_DRAFT" ]; then
    echo "   6) DFlash2       — distilled flash draft: $(basename "$DFLASH_DRAFT")"
  fi
  echo "   7) none          — disable speculative decoding"

  read -rp "Select method [default: $DEFAULT_SPEC]: " SPEC_CHOICE
  case "${SPEC_CHOICE:-$DEFAULT_SPEC}" in
    1)
      if ! is_mtp_model "$NEW_MODEL"; then echo "ERROR: MTP draft requires an MTP model."; exit 1; fi
      read -rp "  MTP draft tokens (n-max) [default: $MTP_DRAFT_N_MAX]: " MTP_N_CHOICE
      if [[ -n "$MTP_N_CHOICE" ]]; then
        if ! [[ "$MTP_N_CHOICE" =~ ^[0-9]+$ ]] || (( MTP_N_CHOICE < 1 || MTP_N_CHOICE > 16 )); then echo "Invalid n-max value (must be 1-16)."; exit 1; fi
        MTP_DRAFT_N_MAX="$MTP_N_CHOICE"
      fi
      NEW_METHOD="draft-mtp"; SPEC_FLAGS="--spec-type draft-mtp --spec-draft-n-max $MTP_DRAFT_N_MAX" ;;
    2)
      NEW_METHOD="ngram-mod"
      read -rp "  Customize ngram-mod params? [y/N]: " NGRAM_CUSTOM
      if [[ "$NGRAM_CUSTOM" =~ ^[Yy]$ ]]; then
        read -rp "    n-match (default $NGRAM_N_MATCH): " TMP_N; [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MATCH="$TMP_N"
        read -rp "    n-min (default $NGRAM_N_MIN): " TMP_N; [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MIN="$TMP_N"
        read -rp "    n-max (default $NGRAM_N_MAX): " TMP_N; [[ "$TMP_N" =~ ^[0-9]+$ ]] && NGRAM_N_MAX="$TMP_N"
      fi
      SPEC_FLAGS="--spec-type ngram-mod --spec-ngram-mod-n-match $NGRAM_N_MATCH --spec-ngram-mod-n-min $NGRAM_N_MIN --spec-ngram-mod-n-max $NGRAM_N_MAX" ;;
    3) NEW_METHOD="ngram-map-k4v"; SPEC_FLAGS="--spec-type ngram-map-k4v" ;;
    4) NEW_METHOD="ngram-map-k"; SPEC_FLAGS="--spec-type ngram-map-k" ;;
    5) NEW_METHOD="ngram-simple"; SPEC_FLAGS="--spec-type ngram-simple" ;;
    6)
      if [ -z "$DFLASH_DRAFT" ]; then echo "ERROR: No DFlash draft model found for $NEW_MODEL"; exit 1; fi
      NEW_METHOD="dflash"; SPEC_FLAGS="--spec-type draft-dflash --model-draft $DFLASH_DRAFT --spec-draft-n-max $DFLASH_DRAFT_N_MAX" ;;
    7|*) NEW_METHOD="none"; SPEC_FLAGS="" ;;
  esac
else
  NEW_METHOD="none"; SPEC_FLAGS=""
fi

echo ""
echo "  New model   : $NEW_MODEL"
echo "  ctx-size    : $NEW_CTX"
echo "  -ngl        : $NEW_NGL"
echo "  KV cache    : $NEW_KV (K and V)"
echo "  Flash Attention : on ( --flash-attn on )"
if [ -n "$SPEC_FLAGS" ]; then echo "  Spec decode : $NEW_METHOD  $SPEC_FLAGS"; else echo "  Spec decode : $NEW_METHOD"; fi
echo ""
read -rp "Apply and restart $SERVICE? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi

rewrite_execstart "$NEW_MODEL" "$NEW_CTX" "$NEW_KV" "$SPEC_FLAGS" "$NEW_NGL"

systemctl daemon-reload
systemctl restart "$SERVICE"

HEALTH_URL="http://127.0.0.1:80/health"
START_RESTARTS="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
OK=0
echo ""
echo "  Waiting for $SERVICE to load ($HEALTH_URL)..."
for i in {1..90}; do
  if curl -fsS -m 3 -o /dev/null "$HEALTH_URL" 2>/dev/null; then OK=1; break; fi
  NR="$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)"
  ST="$(systemctl show -p ActiveState --value "$SERVICE" 2>/dev/null)"
  if [ "$ST" = "failed" ] || { [ -n "$NR" ] && [ "$NR" -gt "$START_RESTARTS" ]; }; then echo "  [✗] $SERVICE entered failed/crash-loop state (NRestarts=$NR)."; break; fi
  sleep 2
done

if [ "$OK" = "1" ]; then
  echo "  [✓] Switched to : $NEW_MODEL"
  echo "  [✓] ctx-size    : $NEW_CTX"
  echo "  [✓] -ngl        : $NEW_NGL"
  echo "  [✓] KV cache    : $NEW_KV (K and V)"
  echo "  [✓] Flash Attn  : on"
  echo "  [✓] Spec decode : $NEW_METHOD"
  if [ -n "$DFLASH_DRAFT" ] && [[ "$NEW_METHOD" == "dflash" ]]; then echo "  [✓] Draft model : $DFLASH_DRAFT"; fi
  echo "  [✓] Service     : $SERVICE running (health OK)"
  echo ""
  echo "  Web UI ready at       : http://$(hostname -I | awk '{print $1}'):80"
  echo "  Verify GPU usage with  : nvidia-smi; nvtop"
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
echo "  --batch-size 512                       — batch size (prompt processing, V100 tuned)"
echo "  --flash-attn on                        — Flash Attention optimized kernel (ctx efficiency + speed)"
echo "  --cache-type-k $NEW_KV / --cache-type-v $NEW_KV — KV cache quantization"
if [ -n "$SPEC_FLAGS" ]; then echo "  $SPEC_FLAGS — speculative decoding ($NEW_METHOD)"; else echo "  (no --spec-type)                     — standard decoding"; fi
echo "  --parallel 1                           — parallel slots"
echo "══════════════════════════════════════════════════════════════════"
echo " Full reconstructed command:"
echo "  /opt/llama.cpp/build/bin/llama-server --model $NEW_MODEL --host 0.0.0.0 --port 80 --ctx-size $NEW_CTX -ngl $NEW_NGL --batch-size 512 --flash-attn on --cache-type-k $NEW_KV --cache-type-v $NEW_KV ${SPEC_FLAGS:+$SPEC_FLAGS }--parallel 1"
echo "══════════════════════════════════════════════════════════════════"

EOS
chmod +x "$SWITCH_SCRIPT"
cp "$SWITCH_SCRIPT" "$SHARED_SWITCH_SCRIPT"
chmod +x "$SHARED_SWITCH_SCRIPT"
rm -f /usr/local/bin/k80-switch-model.sh /usr/local/bin/cuda-switch-model.sh 2>/dev/null || true
rm -f "${MODEL_DIR}/k80-switch-model.sh" "${MODEL_DIR}/cuda-switch-model.sh" 2>/dev/null || true

# --- 6. ENABLE & START ---
echo "[6/7] Enabling $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# --- 7. VERIFICATION ---
echo "[7/7] Verifying..."
nvidia-smi 2>&1 | head -20 || true
nvtop --version 2>&1 | head -n 5 || echo "nvtop: $(which nvtop || echo not found)"
${LLAMA_CPP_DIR}/build/bin/llama-server --version 2>&1 | head -5 || true
systemctl status "$SERVICE_NAME" --no-pager | head -30
echo ""
echo "[Bootstrap complete - V100 CUDA $CUDA_MAJOR + $NVIDIA_DRIVER_VERSION sm70 FA ON, 32GB single-GPU]"
echo "  Web UI: http://<container-ip>:80 (LXC 111 -> 192.168.1.11:80)"
echo "  Switch: egpu-switch-model.sh (also /srv/ai/models/egpu-switch-model.sh)"
echo "  Backend: CUDA sm70 (V100 32GB)"
echo "  Verify: nvidia-smi -L; nvtop; nvidia-smi dmon"
	# --- END BOOTSTRAP LOGIC ---
	exit 0
fi

TARGET_HOST="${HOST_OVERRIDE:-$DEFAULT_HOST}"

# Prefer pct if available and not forced ssh
if ! $VIA_SSH && command -v pct >/dev/null 2>&1 && pct status "$LXC_ID" >/dev/null 2>&1; then
	if pct status "$LXC_ID" 2>&1 | grep -q "running"; then
		echo "[configure] Using pct exec for LXC $LXC_ID ($TARGET_HOST)..."
		pct exec "$LXC_ID" -- mkdir -p /root/ai-engine-bootstrap
		pct push "$LXC_ID" "$0" /root/ai-engine-bootstrap/configure-hlh-ai-engine-egpu.sh --perms 0755
		if [[ -x /usr/bin/nvidia-smi ]]; then
			pct push "$LXC_ID" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755 || true
		fi
		pct exec "$LXC_ID" -- bash /root/ai-engine-bootstrap/configure-hlh-ai-engine-egpu.sh --bootstrap-inside
		echo "[configure] Done via pct exec."
		exit 0
	fi
	echo "[configure] LXC $LXC_ID not running, falling back to ssh $TARGET_HOST"
fi

echo "[configure] Using ssh root@$TARGET_HOST..."
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
if [[ -f "$SSH_KEY" ]]; then SSH_OPTS="$SSH_OPTS -i $SSH_KEY"; fi
scp $SSH_OPTS "$0" root@"$TARGET_HOST":/tmp/configure-hlh-ai-engine-egpu.sh 2>&1 | head -n 20
if [[ -x /usr/bin/nvidia-smi ]]; then
	scp $SSH_OPTS /usr/bin/nvidia-smi root@"$TARGET_HOST":/tmp/nvidia-smi 2>&1 | head -n 20 || true
fi
ssh $SSH_OPTS root@"$TARGET_HOST" "bash /tmp/configure-hlh-ai-engine-egpu.sh --bootstrap-inside" 2>&1
echo "[configure] Done via ssh."
