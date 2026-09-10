#!/usr/bin/env bash
# configure-ai-engine-inside-lxc.sh
# Version: 2.0.0-k80-vulkan
# Description: Bootstrap llama.cpp AI engine on Ubuntu 24.04 LXC with VULKAN for Tesla K80 (GK210 dual cc 3.7) via OCuLink
# Target GPU: NVIDIA Tesla K80 2x GK210GL (12GB per chip, 24GB board) via OCuLink on Minisforum DG2 / Proxmox 9.x privileged LXC
# Backend: GGML_VULKAN=ON, GGML_CUDA=OFF (MTP requires Vulkan on Kepler cc 3.7; CUBLAS_STATUS_ARCH_MISMATCH with CUDA)
# Monitoring: nvidia-utils-470 + libnvidia-compute-470 470.256.02 retained for nvidia-smi/nvtop (no CUDA toolkit)
# Requirements: Run as root inside privileged LXC with /dev/nvidia* passthrough and /srv/ai/models bind mount
# Changelog:
#   2.0.0-k80-vulkan - Vulkan-only: GGML_VULKAN=ON, drop CUDA 11.8 toolkit/gcc-11, keep 470 userspace for nvtop
#   1.0.0-k80 - Fork for hlh-ai-engine-egpu-k80 LXC 131: K80 dual-GK210, CUDA 11.8 + 470.256.02 pinned, GGML_CUDA=ON cc 3.7

set -euo pipefail

# --- PINNED VERSIONS (K80) ---
NVIDIA_DRIVER_VERSION="470.256.02"

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

# --- 1. BASE DEPENDENCIES + VULKAN + 470 USERSPACE (for nvidia-smi/nvtop) ---
echo "[1/7] Installing base dependencies + Vulkan + 470 userspace (monitoring)..."
# Locale + noninteractive to silence perl warnings (seen every apt run)
export DEBIAN_FRONTEND=noninteractive
export LANG=C LC_ALL=C
if ! locale -a 2>&1 | grep -qi "en_US.utf8"; then
  apt-get update && apt-get install -y locales 2>&1 | tail -n 5 || true
  locale-gen en_US.UTF-8 2>&1 | tail -n 5 || true
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>&1 | tail -n 5 || true
fi
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config \
  python3 python3-pip curl wget unzip bc \
  libopenblas-dev libssl-dev ca-certificates gnupg \
  openssh-server \
  libvulkan1 vulkan-tools glslc glslang-tools spirv-tools spirv-headers \
  libvulkan-dev glslang-dev

# Clean up stale CUDA repos/pins from previous 1.x deploys (vulkan-only now)
rm -f /etc/apt/sources.list.d/cuda-ubuntu2204.list /etc/apt/sources.list.d/cuda-debian13.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/jammy-libtinfo5.list 2>/dev/null || true
rm -f /etc/apt/preferences.d/jammy-libtinfo5-pin /etc/apt/preferences.d/jammy-libtinfo5-allow 2>/dev/null || true

# Ensure nvidia userspace is 470 (last for Kepler cc 3.7) for nvidia-smi/nvtop
# Host provides /dev/nvidia* (470 kernel); LXC needs matching userspace 470 for monitoring
# CUDA toolkit is NOT installed in vulkan-only mode.
apt-get update
apt-get install -y --allow-downgrades libnvidia-compute-470=470.256.02-0ubuntu0.24.04.1 2>&1 | tail -n 20 || {
  echo "WARNING: libnvidia-compute-470 470.256.02 not found in noble repo, trying any 470" >&2
  apt-get install -y --allow-downgrades libnvidia-compute-470 2>&1 | tail -n 20 || true
}
apt-get install -y --no-install-recommends nvidia-utils-470=470.256.02-0ubuntu0.24.04.1 2>&1 | tail -n 20 || apt-get install -y --no-install-recommends nvidia-utils-470 2>&1 | tail -n 20 || true
# nvtop for live GPU monitoring (K80 dual)
apt-get install -y --no-install-recommends nvtop 2>&1 | tail -n 10 || echo "WARNING: nvtop not in repo, skipping" >&2
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
# Hold 470 and prevent accidental 535 upgrade (no cuda-* holds in vulkan mode)
apt-mark hold libnvidia-compute-470 nvidia-utils-470 libnvidia-compute-535 nvidia-utils-535 2>&1 | head -n 5 || true
apt-mark unhold cuda-toolkit-11-8 cuda-nvcc-11-8 cuda-cudart-11-8 2>/dev/null || true
# Remove any stale CUDA toolkit left from 1.x (optional, keeps image lean)
# apt-get autoremove -y cuda-toolkit-11-8 cuda-nvcc-11-8 2>&1 | tail -n 10 || true

# Vulkan ICD: 470 on noble provides /usr/share/vulkan/icd.d/nvidia_icd.json via libnvidia-gl-470,
# but libnvidia-gl-470 conflicts with held libnvidia-compute-470 (apt resolver) and pulls 580/535 alongside 470.
# Temporarily unhold, install pinned ICD, purge 580/535 contamination, then re-hold.
mkdir -p /usr/share/vulkan/icd.d /etc/vulkan/icd.d 2>/dev/null || true
if [ ! -f /usr/share/vulkan/icd.d/nvidia_icd.json ] && [ ! -f /etc/vulkan/icd.d/nvidia_icd.json ]; then
  echo "  Note: nvidia_icd.json not found, installing nvidia vulkan icd supplement..."
  apt-mark unhold libnvidia-compute-470 nvidia-utils-470 libnvidia-compute-535 nvidia-utils-535 libnvidia-compute-580 nvidia-utils-580 2>/dev/null || true
  apt-get install -y --allow-downgrades libnvidia-gl-470=470.256.02-0ubuntu0.24.04.1 2>&1 | tail -n 20 || \
    apt-get install -y --allow-downgrades libnvidia-gl-470 2>&1 | tail -n 20 || \
    echo "WARNING: libnvidia-gl-470 install failed (held packages conflict) - Vulkan ICD may be missing, vulkaninfo will fail" >&2
  # Purge 580/535 that apt drags in alongside 470 (causes NVML 580.173 mismatch vs 470 kernel + Vulkan loader picking 580's libGLX)
  echo "  Purging 580/535 contamination (keep 470 only)..."
  apt-get purge -y libnvidia-compute-580 nvidia-utils-580 libnvidia-compute-535 nvidia-utils-535 2>&1 | tail -n 20 || true
  apt-get autoremove -y 2>&1 | tail -n 10 || true
  # Re-ensure 470 is correct after purge (symlinks may have flipped to 580)
  apt-get install -y --allow-downgrades --no-install-recommends libnvidia-compute-470=470.256.02-0ubuntu0.24.04.1 nvidia-utils-470=470.256.02-0ubuntu0.24.04.1 2>&1 | tail -n 20 || true
  if [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.470.256.02 ]; then
    ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
    ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so 2>&1 | head -n 5 || true
    ldconfig 2>&1 | head -n 5 || true
  fi
  apt-mark hold libnvidia-compute-470 nvidia-utils-470 libnvidia-compute-535 nvidia-utils-535 libnvidia-compute-580 nvidia-utils-580 2>&1 | head -n 5 || true
  # Fallback: generate minimal ICD if package unavailable but driver libs exist
  if [ ! -f /usr/share/vulkan/icd.d/nvidia_icd.json ] && [ -f /usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.470.256.02 ]; then
    cat > /usr/share/vulkan/icd.d/nvidia_icd.json <<'ICD'
{
  "file_format_version" : "1.0.0",
  "ICD": {
    "library_path" : "libGLX_nvidia.so.0",
    "api_version" : "1.2.142"
  }
}
ICD
    echo "  Generated fallback nvidia_icd.json" >&2
  fi
fi
# Fix ICD library_path: generic libGLX_nvidia.so.0 may resolve to 580 after multi-version install; pin to 470
if [ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]; then
  if grep -q '"library_path" : "libGLX_nvidia.so.0"' /usr/share/vulkan/icd.d/nvidia_icd.json 2>/dev/null; then
    # Prefer explicit 470 path if exists
    if [ -f /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.470.256.02 ]; then
      sed -i 's#"library_path" : "libGLX_nvidia.so.0"#"library_path" : "/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.470.256.02"#' /usr/share/vulkan/icd.d/nvidia_icd.json || true
      echo "  Patched ICD library_path to 470 explicit" >&2
    fi
  fi
  cat /usr/share/vulkan/icd.d/nvidia_icd.json 2>&1 | head -n 20 || true
fi
echo "  Vulkan ICDs:"
ls -l /usr/share/vulkan/icd.d/ 2>&1 | head -n 20 || true
ls -l /etc/vulkan/icd.d/ 2>&1 | head -n 20 || true
# Final NVML sanity: ensure 580 not present
dpkg -l | grep -E "libnvidia-compute|nvidia-utils" 2>&1 | head -n 20 || true
ls -l /usr/lib/x86_64-linux-gnu/libnvidia-ml.so* 2>&1 | head -n 20 || true
ldconfig -p 2>&1 | grep -E "libnvidia-ml|libGLX_nvidia" | head -n 20 || true

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
echo "[1/7] Verifying Vulkan + K80 dual-GPU (nvidia-smi for monitoring)... [host driver must be healthy first]"
# Locale already fixed at top; ensure exports persist
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
# Fix nvidia-smi inside LXC (host driver 470.256.02, LXC apt may leave broken symlink to non-existent /usr/lib/nvidia-470/bin/nvidia-smi)
if [ -L /usr/bin/nvidia-smi ] && [ ! -e /usr/bin/nvidia-smi ]; then rm -f /usr/bin/nvidia-smi; fi
if [ ! -x /usr/bin/nvidia-smi ] && [ -x /tmp/nvidia-smi ]; then cp /tmp/nvidia-smi /usr/bin/nvidia-smi; chmod +x /usr/bin/nvidia-smi; fi
if [ -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.470.256.02 ]; then
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>&1 | head -n 5 || true
  ln -sf libnvidia-ml.so.470.256.02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so 2>&1 | head -n 5 || true
  ldconfig 2>&1 | head -n 5 || true
fi
# Use set +o pipefail for nvidia-smi | head to avoid SIGPIPE with pipefail
# NOTE: nvidia-smi Unknown Error for 0000:C7/C8 means HOST driver mismatch (470 vs kernel 7.x) - not LXC fault.
# See prox01: dkms status; modinfo nvidia | grep version; dmesg | grep -i NVRM; reboot or modprobe -r nvidia_uvm/nvidia && modprobe nvidia
set +o pipefail
nvidia-smi -L 2>&1 | head -20 || {
  echo "WARNING: nvidia-smi failed (host driver not talking to K80 0000:C7/C8). Host fix needed:" >&2
  echo "  prox01: dkms status | grep nvidia; modinfo nvidia | head; dmesg | grep -i nvidia | tail -n 30" >&2
  echo "  prox01: ls -l /dev/nvidia*; cat /proc/driver/nvidia/version 2>&1 | head" >&2
  echo "  prox01: reboot OR modprobe -r nvidia_uvm nvidia_modeset nvidia_drm nvidia && modprobe nvidia && nvidia-modprobe -u -c 0" >&2
  ls -l /dev/nvidia* 2>&1 | head -20
  ls -l /usr/bin/nvidia-smi* 2>&1 | head -n 20
  echo "Continuing to Vulkan build (will fail vulkaninfo if host still broken)..." >&2
}
set -o pipefail
echo "  nvidia-smi -L:"
nvidia-smi -L 2>&1 | head -n 20 || true
echo "  Checking both GK210 chips (expect 2 GPUs):"
GPU_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || true)
set +o pipefail
if [ "$GPU_COUNT" -ne 2 ]; then echo "WARNING: Expected 2 K80 GPUs, found $GPU_COUNT (host driver Unknown Error is root cause)" >&2; fi
echo "  Pinned: Vulkan + driver $NVIDIA_DRIVER_VERSION (470 EOL, CUDA monitoring only)"
echo "  vulkaninfo --summary:"
vulkaninfo --summary 2>&1 | head -n 60 || echo "vulkaninfo failed - check nvidia_icd.json and /dev/nvidia* (host driver must be healthy)"
echo "  Vulkan devices via vulkaninfo:"
vulkaninfo 2>&1 | grep -E "GPU|deviceName|driverID" | head -n 20 || true

# --- 2. BUILD LLAMA.CPP (VULKAN) ---
echo "[2/7] Cloning and building llama.cpp (VULKAN)..."
# Vulkan needs glslc (from glslang-tools/shaderc) - already installed above; verify
command -v glslc >/dev/null 2>&1 || { echo "ERROR: glslc not found for Vulkan build" >&2; exit 1; }
# No gcc-11 pin needed for Vulkan (noble gcc 13 is fine); ensure alternatives sane
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone --depth=1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
else
  git -C "$LLAMA_CPP_DIR" pull
fi

cd "$LLAMA_CPP_DIR"

# Vulkan-only: MTP works via Vulkan (no CUBLAS_STATUS_ARCH_MISMATCH on cc 3.7)
cmake -S . -B build \
  -DGGML_VULKAN=ON \
  -DGGML_CUDA=OFF \
  -DGGML_HIP=OFF \
  -DCMAKE_BUILD_TYPE=Release

echo "[2/7] Building... (this can take 15-30 minutes with 12 cores, Vulkan)"
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

# --- 3. MODEL STORAGE (bind mount — same path host and CT) ---
# Host RaidZ1-6TB ZFS dataset /srv/ai/models is bind-mounted via --mp0 into LXC at /srv/ai/models.
# Models are already present on host after mount — CT does not download. We pick the active
# model from the shared directory.
echo "[3/7] Setting up model directory (bind mount host == CT: $MODEL_DIR)..."
mkdir -p "$MODEL_DIR"
# Verify mount is active (should show ZFS or bind)
mount | grep -E "on ${MODEL_DIR} " | head -3 || echo "  (no mount yet — may be bind from host)"
ls -lh "$MODEL_DIR" | head -20 || true
cd "$MODEL_DIR"

ACTIVE_MODEL_FILE=""

if [ -f "${MODEL_DIR}/${DEFAULT_MODEL_FILE}" ]; then
  ACTIVE_MODEL_FILE="$DEFAULT_MODEL_FILE"
  echo "Default model already present on shared mount: $ACTIVE_MODEL_FILE"
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

# Validate active model exists
if [ ! -f "${MODEL_DIR}/${ACTIVE_MODEL_FILE}" ]; then
  echo "WARNING: Active model file not found: ${MODEL_DIR}/${ACTIVE_MODEL_FILE} — ai-engine will fail to start until host populates /srv/ai/models" >&2
fi

# --- 4. SYSTEMD SERVICE ---
echo "[4/7] Creating systemd service for llama-server (Vulkan)..."
cat > "$SYSTEMD_SERVICE" << UNIT
[Unit]
Description=llama.cpp AI Engine (llama-server) - Vulkan K80 on port 80 - driver $NVIDIA_DRIVER_VERSION (vulkan-only, MTP enabled)
After=network.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_CPP_DIR}/build/bin
Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
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
# Refactored from hlh-ai-engine switch-model.sh v1.7.0, tuned for K80 Vulkan (MTP enabled)
# Changes vs upstream: banner/K80 VRAM table (2x12GB=24GB), -ngl 99, --batch-size 512,
# vulkan verify via vulkaninfo, nvidia-smi for monitoring only.
echo "[5/7] Creating model switcher: $SWITCH_SCRIPT (Tesla K80 dual GK210 Vulkan) -> $SHARED_SWITCH_SCRIPT..."
cat > "$SWITCH_SCRIPT" << 'EOS'
#!/usr/bin/env bash
# k80-switch-model.sh
# Version: 2.0.0-k80-vulkan
# Description: Interactive model switcher for llama.cpp ai-engine service (Tesla K80 dual GK210 Vulkan)
# Supports: model selection, ctx-size, KV cache quantization, speculative decoding method (MTP draft / ngram / none)
# Refactored from hlh-ai-engine switch-model.sh v1.7.0 for K80 Vulkan + 470.256.02 (MTP enabled via Vulkan)
# K80 dual: 2x GK210GL 12GB per chip = 24GB board via OCuLink, Vulkan devices 0,1 (not CUDA_VISIBLE_DEVICES)
# Changelog:
#   2.0.0-k80-vulkan - Vulkan-only: banner 24GB, -ngl 99, --batch-size 512, verify via vulkaninfo + nvidia-smi monitoring
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
echo "║        k80-switch-model.sh (Tesla K80 dual GK210 VULKAN)        ║"
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
K80_COUNT=$(nvidia-smi -L 2>&1 | grep -c "GPU [0-9]:" || echo "?")

echo "  Model directory : $MODEL_DIR"
echo "  Currently active: $CUR_MODEL"
echo "  ctx-size        : ${CUR_CTX:-(not set)}"
echo "  KV cache (K/V)  : ${CUR_KV_K} / ${CUR_KV_V}"
echo "  Spec decode     : $CUR_SPEC"
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
  echo "   1) MTP draft     — use the model's MTP heads (default, n-max $MTP_DRAFT_N_MAX) [Vulkan OK]"
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
  echo "  Verify GPU usage with  : nvidia-smi; nvtop; vulkaninfo --summary"
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
vulkaninfo --summary 2>&1 | head -n 40 || true
nvtop --version 2>&1 | head -n 5 || echo "nvtop: $(which nvtop || echo not found)"
${LLAMA_CPP_DIR}/build/bin/llama-server --version 2>&1 | head -5 || true
systemctl status "$SERVICE_NAME" --no-pager | head -30
echo ""
echo "[Bootstrap complete - k80 Vulkan + 470.256.02 monitoring, dual-GK210 MTP enabled]"
echo "  Web UI: http://<container-ip>:80 (LXC 131 -> 192.168.1.31:80)"
echo "  Switch: k80-switch-model.sh (also /srv/ai/models/k80-switch-model.sh)"
echo "  Backend: Vulkan (MTP) + driver $NVIDIA_DRIVER_VERSION for nvidia-smi/nvtop"
echo "  Verify: vulkaninfo --summary; nvidia-smi -L; nvtop"
