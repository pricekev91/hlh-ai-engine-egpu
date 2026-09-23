#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/configure-hlh-ai-engine-v100.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine-v100.sh [--skip-host-driver]

V100 eGPU path (Tesla V100 GV100GL 32GB via OCuLink) - CUDA:
	1) Verify/install NVIDIA 550/580 on Proxmox host (pinned, Volta GV100 cc 7.0)
	2) Create privileged LXC 131 (hlh-ai-engine-v100) at 192.168.1.31
	3) Add cgroup + /dev/nvidia* bind-mounts for single GV100 (c5:00.0)
	4) Start container + push/run CUDA bootstrap (GGML_CUDA=ON arch 70, FA ON)

NOTES:
	- Single OCuLink slot: LXC 130 (vulkan) and 131 (v100) cannot run together.
	  The script stops 130 if running and documents manual swap.
	- V100 is Volta (cc 7.0) - last driver R580 (580.65.06) is last supporting Volta.
	  Debian trixie stable currently packages 550.163.01 (supports CUDA 12.4).
	  Script pins host to 550.163.01-2 (trixie non-free) + LXC CUDA 12.4 from ubuntu2404.
	  Override via NVIDIA_DRIVER_VERSION env to use 580 when Debian packages it.
	  CUDA toolkit in LXC is 12.4 (12.8 requires 570+ driver - update host first).
	  Host needs nouveau blacklisted + reboot. Single GPU 32GB at 0000:c5:00.0.
EOF
}

# --- PINNED VERSIONS (V100 Volta cc 7.0) ---
# Last stable for Volta: R580 (580.65.06) + CUDA 12.8/12.9 is final sm_70 support.
# NOTE 2026-09-23: Proxmox kernel 7.0.14-11-pve breaks 550.163.01 DKMS (__vm_flags / VMA-lock / in_irq).
# 550 builds on 6.5.13-5-pve but not 7.0 (tested). 470.256.02 (runfile) still builds on 7.0 and drives V100 (CUDA 11.4).
# Therefore default host pin stays 470 for kernel 7.0 until 580 packaged for trixie or patch. LXC uses CUDA 11.8 (matches 470).
# For kernel 6.5 or when 580 available: export NVIDIA_DRIVER_VERSION="550.163.01-2" DRIVER_BRANCH="550" CUDA_VERSION="12.4.1"
# Or for 580: export NVIDIA_DRIVER_VERSION="580.65.06-1" DRIVER_BRANCH="580" CUDA_VERSION="12.8.1"
KERNEL_MAJ=$(uname -r | cut -d. -f1)
if [[ "$KERNEL_MAJ" -ge 7 ]]; then
  DEFAULT_DRIVER="470.256.02-1~deb11u2"
  DEFAULT_SHORT="470.256.02"
  DEFAULT_CUDA="11.8.0-1"
  DEFAULT_MAJOR="11.8"
  DEFAULT_BRANCH="470"
else
  DEFAULT_DRIVER="550.163.01-2"
  DEFAULT_SHORT="550.163.01"
  DEFAULT_CUDA="12.4.1"
  DEFAULT_MAJOR="12.4"
  DEFAULT_BRANCH="550"
fi
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-$DEFAULT_DRIVER}"
NVIDIA_DRIVER_VERSION_SHORT="${NVIDIA_DRIVER_VERSION_SHORT:-$DEFAULT_SHORT}"
CUDA_VERSION="${CUDA_VERSION:-$DEFAULT_CUDA}"
CUDA_MAJOR="${CUDA_MAJOR:-$DEFAULT_MAJOR}"
DRIVER_BRANCH="${DRIVER_BRANCH:-$DEFAULT_BRANCH}"

LXC_ID=131
LXC_NAME="hlh-ai-engine-v100"
LXC_HOSTNAME="hlh-ai-engine-v100"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/srv/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
LXC_ROOTFS_SIZE="64"
LXC_MEMORY="8192"
LXC_CORES="12"
LXC_IP_CONFIG="192.168.1.31/24"
LXC_GATEWAY="192.168.1.1"

SKIP_HOST_DRIVER=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-host-driver) SKIP_HOST_DRIVER=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

command -v pct >/dev/null 2>&1 || { echo "ERROR: pct not found. Run on Proxmox host." >&2; exit 1; }
[[ -f "$BOOTSTRAP_SCRIPT" ]] || { echo "ERROR: Bootstrap not found: $BOOTSTRAP_SCRIPT" >&2; exit 1; }

confirm_existing_lxc_delete() {
	local answer
	printf '%s\n' 'Are you sure?  hlh-ai-engine-v100 is already running!'
	printf '%s' 'Delete it and redeploy? [y/N] '
	read -r answer
	case "$answer" in y|Y|yes|YES) return 0 ;; *) echo "Aborted." >&2; exit 1 ;; esac
}

# --- V100 helpers: single GV100 ---
detect_v100_pcis() {
	# V100 shows as single 3D controller at c5:00.0 (GV100GL 10de:1df0)
	lspci -nn -D 2>/dev/null | grep -i "10de:1df0" | awk '{print $1}' | sort
}

get_iommu_for() { readlink "/sys/bus/pci/devices/$1/iommu_group" 2>/dev/null || true; }

# --- 0/6 Host driver (pinned) ---
if [[ "$SKIP_HOST_DRIVER" == "false" ]]; then
	echo "[0/6] Host NVIDIA driver check (pinned: nvidia-driver $NVIDIA_DRIVER_VERSION_SHORT Volta GV100 sm70, CUDA $CUDA_MAJOR)..."
	if lsmod | grep "nvidia" >/dev/null && modinfo nvidia 2>/dev/null | grep "$DRIVER_BRANCH" >/dev/null; then
		echo "  Host driver already loaded: $(modinfo nvidia 2>/dev/null | grep ^version: | head -1)"
		set +o pipefail; nvidia-smi 2>&1 | head -10 || true; set -o pipefail
		# Ensure nvidia_uvm persists across reboot
		if [ ! -f /etc/modules-load.d/nvidia.conf ]; then
			echo "  - Installing /etc/modules-load.d/nvidia.conf for nvidia_uvm persistence"
			cat > /etc/modules-load.d/nvidia.conf <<'MOD'
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
MOD
		fi
		if [ ! -f /etc/systemd/system/nvidia-uvm-devices.service ]; then
			echo "  - Installing nvidia-uvm-devices.service (Before pve-guests.service)"
			cat > /etc/systemd/system/nvidia-uvm-devices.service <<'SVC'
[Unit]
Description=Create NVIDIA UVM device nodes for LXC passthrough (V100 Volta)
Before=pve-guests.service
After=systemd-modules-load.service
Wants=systemd-modules-load.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'set -e; /sbin/modprobe nvidia || true; /sbin/modprobe nvidia_uvm || true; /sbin/modprobe nvidia_modeset || true; /sbin/modprobe nvidia_drm || true; /usr/bin/nvidia-modprobe -u -c 0 || true; UVM_MAJOR=$(grep -m1 nvidia-uvm /proc/devices 2>/dev/null | awk "{print $1}"); [ -n "$UVM_MAJOR" ] || UVM_MAJOR=511; if [ ! -c /dev/nvidia-uvm ]; then /bin/mknod -m 666 /dev/nvidia-uvm c $UVM_MAJOR 0 2>/dev/null || true; fi; if [ ! -c /dev/nvidia-uvm-tools ]; then /bin/mknod -m 666 /dev/nvidia-uvm-tools c $UVM_MAJOR 1 2>/dev/null || true; fi; /bin/chmod 666 /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true; /bin/mknod -m 666 /dev/nvidia-modeset c 195 254 2>/dev/null || /bin/chmod 666 /dev/nvidia-modeset 2>/dev/null || true; ls -l /dev/nvidia* 2>&1 | head -n 20'

[Install]
WantedBy=multi-user.target
SVC
			systemctl daemon-reload
			systemctl enable nvidia-uvm-devices.service >/dev/null 2>&1 || true
		fi
		systemctl start nvidia-uvm-devices.service >/dev/null 2>&1 || true
		/sbin/modprobe nvidia_uvm 2>/dev/null || true
		/usr/bin/nvidia-modprobe -u -c 0 2>/dev/null || true
		UVM_MAJOR=$(grep -m1 nvidia-uvm /proc/devices 2>/dev/null | awk '{print $1}'); [ -n "$UVM_MAJOR" ] || UVM_MAJOR=511
		[ -c /dev/nvidia-uvm ] || mknod -m 666 /dev/nvidia-uvm c "$UVM_MAJOR" 0 2>/dev/null || true
		[ -c /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c "$UVM_MAJOR" 1 2>/dev/null || true
		[ -c /dev/nvidia-modeset ] || mknod -m 666 /dev/nvidia-modeset c 195 254 2>/dev/null || true
		chmod 666 /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
	else
		echo "  Installing/blacklisting for V100 (Volta)..."
		echo "  - Blacklisting nouveau"
		cat > /etc/modprobe.d/blacklist-nouveau-v100.conf <<'BLK'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
BLK
		# Remove stale bullseye 470 repo
		rm -f /etc/apt/sources.list.d/bullseye-nvidia-tesla-470.list 2>/dev/null || true
		echo "  - Ensuring Debian trixie non-free for nvidia-driver (pinned $NVIDIA_DRIVER_VERSION)"
		# Debian sources are in /etc/apt/sources.list.d/debian.sources - ensure non-free enabled
		grep -q "non-free" /etc/apt/sources.list.d/debian.sources 2>/dev/null || echo "  WARNING: non-free not enabled in debian.sources" >&2
		# Also add CUDA repo for reference (provides nvidia-driver 590+ but not 550; we keep for cuda toolkit headers if needed)
		if [ ! -f /etc/apt/sources.list.d/cuda-debian13.list ]; then
			curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/8793F200.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg 2>/dev/null || true
			echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64 /" > /etc/apt/sources.list.d/cuda-debian13.list
		fi
		apt update
		echo "  - Installing nvidia-driver=$NVIDIA_DRIVER_VERSION (DKMS) - Volta GV100 cc 7.0"
		# Prefer exact pin, fallback to any 550/580 available
		apt install -y --no-install-recommends nvidia-driver=${NVIDIA_DRIVER_VERSION} nvidia-settings 2>&1 | tail -n 30 || \
		apt install -y --no-install-recommends nvidia-driver nvidia-settings 2>&1 | tail -n 30
		echo "  - Updating initramfs and reboot required"
		update-initramfs -u
		echo "  Host driver stage complete. Rebooting prox01 in 5s (Ctrl+C to abort)..."
		sleep 5
		reboot
		exit 0
	fi
else
	echo "[0/6] Skipping host driver install (--skip-host-driver)"
fi

# Validate V100 present and driver
echo "[0/6] Validating V100..."
V100_PCI_LIST=$(detect_v100_pcis || true)
if [ -z "$V100_PCI_LIST" ]; then echo "ERROR: No V100 (10de:1df0) detected via lspci. Is OCuLink seated? (expected 0000:c5:00.0)" >&2; lspci -nn | grep -i nvidia || true; exit 1; fi
echo "  Detected V100 PCI addresses:"
echo "$V100_PCI_LIST" | sed 's/^/    /'
V100_COUNT=$(echo "$V100_PCI_LIST" | wc -l)
if [ "$V100_COUNT" -ne 1 ]; then echo "WARNING: Expected 1 GV100 chip, found $V100_COUNT. Continuing." >&2; fi
if ! lsmod | grep "nvidia" >/dev/null; then echo "ERROR: nvidia module not loaded. Run without --skip-host-driver." >&2; exit 1; fi
set +o pipefail; nvidia-smi -L 2>&1 | head -10 || { echo "nvidia-smi failed"; exit 1; }; set -o pipefail
nvidia-smi 2>&1 | head -20 || true

echo "[1/6] Creating model storage directory on ${POOL}..."
mkdir -p "${MODEL_HOST_DIR}"
chown 0:0 "${MODEL_HOST_DIR}"
chmod 755 "${MODEL_HOST_DIR}"

# Single slot arbitration: stop 130 if running
if pct status 130 >/dev/null 2>&1; then
	if pct status 130 2>&1 | grep -q "running"; then
		echo "[1/6] Stopping LXC 130 (hlh-ai-engine-egpu-vulkan) — single OCuLink slot"
		pct stop 130 || true
		sleep 3
	fi
fi

if pct status "${LXC_ID}" >/dev/null 2>&1; then
	confirm_existing_lxc_delete
	echo "[1/6] Deleting existing LXC ${LXC_ID}..."
	pct stop "${LXC_ID}" >/dev/null 2>&1 || true
	pct destroy "${LXC_ID}" >/dev/null 2>&1 || pct delete "${LXC_ID}"
fi

echo "[2/6] Creating privileged Ubuntu LXC (${LXC_ID}, ${LXC_NAME}) on ${POOL}..."
pct create "${LXC_ID}" "${LXC_IMAGE}" \
	--storage "${POOL}" \
	--rootfs "${LXC_ROOTFS_SIZE}" \
	--hostname "${LXC_HOSTNAME}" \
	--memory "${LXC_MEMORY}" \
	--cores "${LXC_CORES}" \
	--features nesting=1,keyctl=1,fuse=1 \
	--net0 name=eth0,bridge=vmbr0,ip=${LXC_IP_CONFIG},gw=${LXC_GATEWAY} \
	--unprivileged 0 \
	--onboot 1 \
	--mp0 "${MODEL_HOST_DIR},mp=${MODEL_LXC_DIR}" \
	--description "llama.cpp AI engine CUDA $CUDA_MAJOR + driver $NVIDIA_DRIVER_VERSION_SHORT for Tesla V100 (GV100 32GB cc 7.0) via OCuLink c5:00.0, model storage on ${POOL} — CUDA FA ON, 32GB single-GPU"

echo "[3/6] Adding V100 CUDA passthrough (single GV100 32GB + UVM)..."
# V100 presents as single PCI device c5:00.0 (10de:1df0) IOMMU 20. LXC passthrough via /dev, not hostpci.
# Host /dev/nvidia* is created by nvidia driver after modprobe; expose via cgroup + bind-mount.
# If host uses dynamic UVM major (507/511), covers both. nvidia-modeset is 195:254.
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<'LXCCONF'

# V100 Tesla GV100 32GB (cc 7.0) — CUDA + driver 550/580 pinned, single GPU
# c5:00.0 (10de:1df0) via OCuLink 00:03.1 GPP x4; IOMMU group 20
# Expose single chip as nvidia0 plus control nodes (CUDA)
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 507:* rwm
lxc.cgroup2.devices.allow: c 510:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
LXCCONF

echo "[4/6] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

echo "[5/6] Running in-container CUDA bootstrap (CUDA $CUDA_MAJOR, driver $DRIVER_BRANCH, sm70 FA ON)..."
pct exec "${LXC_ID}" -- mkdir -p /root/ai-engine-bootstrap
pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/ai-engine-bootstrap/configure-hlh-ai-engine-v100.sh --perms 0755
pct push "${LXC_ID}" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755
pct exec "${LXC_ID}" -- bash /root/ai-engine-bootstrap/configure-hlh-ai-engine-v100.sh --bootstrap-inside

echo "[6/6] Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) is running."
echo "Model storage: ${MODEL_HOST_DIR} (host) <-> ${MODEL_LXC_DIR} (container) on ${POOL} (755, root managed)"
echo "Access llama-server at http://192.168.1.31:80"
echo "Host driver pinned: $NVIDIA_DRIVER_VERSION_SHORT (branch $DRIVER_BRANCH) CUDA $CUDA_MAJOR Volta V100 32GB sm70"
echo "Verify inside LXC: nvidia-smi -L && nvidia-smi && /opt/llama.cpp/build/bin/llama-server --version && nvidia-smi dmon"
echo "Note: Single OCuLink slot — stop 131 before starting 130: pct stop 131 && pct start 130"
