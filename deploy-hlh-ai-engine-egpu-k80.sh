#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/ansible/files/configure-ai-engine-inside-lxc.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine-egpu-k80.sh [--skip-host-driver]

K80 eGPU path (Tesla K80 GK210GL dual-GPU via OCuLink):
	1) Verify/install NVIDIA 470 + CUDA 11.8 on Proxmox host (pinned)
	2) Create privileged LXC 131 (hlh-ai-engine-egpu-k80) at 192.168.1.31
	3) Add cgroup + /dev/nvidia* bind-mounts for both GK210 chips (c7 + c8)
	4) Start container + push/run CUDA bootstrap (GGML_CUDA=ON, cc 3.7)

NOTES:
	- Single OCuLink slot: LXC 130 (vulkan) and 131 (k80) cannot run together.
	  The script stops 130 if running and documents manual swap.
	- K80 is Kepler (cc 3.7) EOL: latest driver 470.256.02 + CUDA 11.8 is pinned.
	  CUDA 12+ drops Kepler. Host needs nouveau blacklisted + reboot.
EOF
}

# --- PINNED VERSIONS (K80) ---
NVIDIA_TESLA_470_VERSION="470.256.02-1~deb11u2"  # Debian bullseye nvidia-tesla-470-driver
NVIDIA_TESLA_470_VERSION_SHORT="470.256.02"
CUDA_VERSION="11.8.0-1"                         # CUDA 11.8 from NVIDIA repo (ubuntu2404/debian13)
CUDA_MAJOR="11.8"
DRIVER_BRANCH="470"

LXC_ID=131
LXC_NAME="hlh-ai-engine-egpu-k80"
LXC_HOSTNAME="hlh-ai-engine-egpu-k80"
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
	printf '%s\n' 'Are you sure?  hlh-ai-engine-egpu-k80 is already running!'
	printf '%s' 'Delete it and redeploy? [y/N] '
	read -r answer
	case "$answer" in y|Y|yes|YES) return 0 ;; *) echo "Aborted." >&2; exit 1 ;; esac
}

# --- K80 helpers: dual GK210 ---
detect_k80_pcis() {
	# K80 shows as two 3D controllers: c7:00.0 + c8:00.0 (GK210GL)
	lspci -nn -D 2>/dev/null | grep -i "10de:102d" | awk '{print $1}' | sort
}

get_iommu_for() { readlink "/sys/bus/pci/devices/$1/iommu_group" 2>/dev/null || true; }

# --- 0/6 Host driver (pinned) ---
if [[ "$SKIP_HOST_DRIVER" == "false" ]]; then
	echo "[0/6] Host NVIDIA driver check (pinned: nvidia-tesla-470 $NVIDIA_TESLA_470_VERSION_SHORT + CUDA $CUDA_MAJOR)..."
	if lsmod | grep "nvidia" >/dev/null && modinfo nvidia 2>/dev/null | grep "$DRIVER_BRANCH" >/dev/null; then
		echo "  Host driver already loaded: $(modinfo nvidia 2>/dev/null | grep ^version: | head -1)"
		set +o pipefail; nvidia-smi 2>&1 | head -5 || true; set -o pipefail
		# Ensure nvidia_uvm persists across reboot (fixes CPU fallback: missing /dev/nvidia-uvm)
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
Description=Create NVIDIA UVM device nodes for LXC passthrough (K80)
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
		# Ensure devices exist now (host reboot left them missing) — dynamic major
		/sbin/modprobe nvidia_uvm 2>/dev/null || true
		/usr/bin/nvidia-modprobe -u -c 0 2>/dev/null || true
		UVM_MAJOR=$(grep -m1 nvidia-uvm /proc/devices 2>/dev/null | awk '{print $1}'); [ -n "$UVM_MAJOR" ] || UVM_MAJOR=511
		[ -c /dev/nvidia-uvm ] || mknod -m 666 /dev/nvidia-uvm c "$UVM_MAJOR" 0 2>/dev/null || true
		[ -c /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c "$UVM_MAJOR" 1 2>/dev/null || true
		[ -c /dev/nvidia-modeset ] || mknod -m 666 /dev/nvidia-modeset c 195 254 2>/dev/null || true
		chmod 666 /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
	else
		echo "  Installing/blacklisting for K80..."
		echo "  - Blacklisting nouveau"
		cat > /etc/modprobe.d/blacklist-nouveau-k80.conf <<'BLK'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
BLK
		echo "  - Adding Debian bullseye non-free for nvidia-tesla-470 (pinned $NVIDIA_TESLA_470_VERSION)"
		cat > /etc/apt/sources.list.d/bullseye-nvidia-tesla-470.list <<'SRC'
deb http://deb.debian.org/debian bullseye non-free
deb http://security.debian.org/debian-security bullseye-security non-free
SRC
		echo "  - Adding NVIDIA CUDA repo for CUDA $CUDA_MAJOR (debian13)"
		curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/8793F200.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg 2>/dev/null || true
		echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64 /" > /etc/apt/sources.list.d/cuda-debian13.list
		apt update
		echo "  - Installing nvidia-tesla-470-driver=$NVIDIA_TESLA_470_VERSION (DKMS)"
		# Prefer exact pin, fallback to latest 470 in bullseye
		apt install -y --no-install-recommends nvidia-tesla-470-driver=${NVIDIA_TESLA_470_VERSION} nvidia-tesla-470-nvidia-settings nvidia-tesla-470-opencl-icd 2>&1 | tail -n 20 || \
		apt install -y --no-install-recommends nvidia-tesla-470-driver nvidia-tesla-470-opencl-icd
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

# Validate K80 present and driver
echo "[0/6] Validating K80..."
K80_PCI_LIST=$(detect_k80_pcis || true)
if [ -z "$K80_PCI_LIST" ]; then echo "ERROR: No K80 (10de:102d) detected via lspci. Is OCuLink seated?" >&2; exit 1; fi
echo "  Detected K80 PCI addresses:"
echo "$K80_PCI_LIST" | sed 's/^/    /'
K80_COUNT=$(echo "$K80_PCI_LIST" | wc -l)
if [ "$K80_COUNT" -ne 2 ]; then echo "WARNING: Expected 2 GK210 chips, found $K80_COUNT. Continuing." >&2; fi
if ! lsmod | grep "nvidia" >/dev/null; then echo "ERROR: nvidia module not loaded. Run without --skip-host-driver." >&2; exit 1; fi
set +o pipefail; nvidia-smi -L 2>&1 | head -10 || { echo "nvidia-smi failed"; exit 1; }; set -o pipefail

echo "[1/6] Creating model storage directory on ${POOL}..."
mkdir -p "${MODEL_HOST_DIR}"
chown 0:0 "${MODEL_HOST_DIR}"
chmod 775 "${MODEL_HOST_DIR}"

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
	--description "llama.cpp AI engine with CUDA 11.8 + driver 470.256.02 for Tesla K80 (GK210 dual cc 3.7) via OCuLink, model storage on ${POOL} — pinned CUDA $CUDA_VERSION"

echo "[3/6] Adding K80 CUDA passthrough (dual GK210 + UVM)..."
# K80 presents as two PCI devices (c7/c8) but LXC passthrough is via /dev, not hostpci.
# Host /dev/nvidia* is created by nvidia driver after modprobe; expose via cgroup + bind-mount.
# We use allow-all for 195 (nvidia) and 511 (nvidia-uvm) and mount the 5 nodes.
# If host uses 510 for uvm, the optional mount covers it.
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<'LXCCONF'

# K80 Tesla GK210 dual-GPU (cc 3.7) — CUDA 11.8 + driver 470.256.02 pinned
# c7:00.0 + c8:00.0 (10de:102d) share OCuLink switch; IOMMU groups 23/24 separate
# Expose both chips as nvidia0 + nvidia1 plus control nodes
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 507:* rwm
lxc.cgroup2.devices.allow: c 510:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidia1 dev/nvidia1 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
LXCCONF

echo "[4/6] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

echo "[5/6] Running in-container CUDA bootstrap (pinned: CUDA $CUDA_VERSION, driver $DRIVER_BRANCH)..."
pct exec "${LXC_ID}" -- mkdir -p /root/ai-engine-bootstrap
pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh --perms 0755
pct push "${LXC_ID}" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755
pct exec "${LXC_ID}" -- bash /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh

echo "[6/6] Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) is running."
echo "Model storage: ${MODEL_HOST_DIR} (host) <-> ${MODEL_LXC_DIR} (container) on ${POOL}"
echo "Access llama-server at http://192.168.1.31:80"
echo "Host driver pinned: $NVIDIA_TESLA_470_VERSION_SHORT (470) + CUDA $CUDA_VERSION"
echo "Verify inside LXC: nvidia-smi -L && nvidia-smi && /opt/llama.cpp/build/bin/llama-server --list-devices"
echo "Note: Single OCuLink slot — stop 131 before starting 130: pct stop 131 && pct start 130"
