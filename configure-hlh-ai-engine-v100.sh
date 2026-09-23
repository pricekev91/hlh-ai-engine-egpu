#!/usr/bin/env bash
set -euo pipefail

# configure-hlh-ai-engine-v100.sh - Reconfigure existing hlh-ai-engine-v100 LXC via bash (no ansible)
# Usage: ./configure-hlh-ai-engine-v100.sh [--host <ip>] [--via-ssh]
# Default reuses pct exec if LXC 131 is on local prox01, otherwise ssh to 192.168.1.31

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/configure-ai-engine-inside-lxc.sh"
LXC_ID=131
DEFAULT_HOST="192.168.1.31"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HOST_OVERRIDE=""
VIA_SSH=false

usage() {
	cat <<'EOF'
Usage:
	./configure-hlh-ai-engine-v100.sh [--host <ip>] [--via-ssh]

Options:
  --host <ip>  Override target host (default 192.168.1.31 or LXC 131 via pct if local)
  --via-ssh   Force ssh even if pct is available (for remote reconfigure)
  -h, --help  Show this help.

This re-runs configure-ai-engine-inside-lxc.sh inside the LXC:
  - via pct exec if running on prox01 and pct status 131 exists
  - otherwise via ssh root@<host>
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--host)
			[[ $# -ge 2 ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
			HOST_OVERRIDE="$2"; shift ;;
		--via-ssh) VIA_SSH=true ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
	shift
done

[[ -f "$BOOTSTRAP_SCRIPT" ]] || { echo "ERROR: Bootstrap not found: $BOOTSTRAP_SCRIPT" >&2; exit 1; }

TARGET_HOST="${HOST_OVERRIDE:-$DEFAULT_HOST}"

# Prefer pct if available and not forced ssh
if ! $VIA_SSH && command -v pct >/dev/null 2>&1 && pct status "$LXC_ID" >/dev/null 2>&1; then
	if pct status "$LXC_ID" 2>&1 | grep -q "running"; then
		echo "[configure] Using pct exec for LXC $LXC_ID ($TARGET_HOST)..."
		pct exec "$LXC_ID" -- mkdir -p /root/ai-engine-bootstrap
		pct push "$LXC_ID" "$BOOTSTRAP_SCRIPT" /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh --perms 0755
		if [[ -x /usr/bin/nvidia-smi ]]; then
			pct push "$LXC_ID" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755 || true
		fi
		pct exec "$LXC_ID" -- bash /root/ai-engine-bootstrap/configure-ai-engine-inside-lxc.sh
		echo "[configure] Done via pct exec."
		exit 0
	fi
	echo "[configure] LXC $LXC_ID not running, falling back to ssh $TARGET_HOST"
fi

echo "[configure] Using ssh root@$TARGET_HOST..."
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
if [[ -f "$SSH_KEY" ]]; then SSH_OPTS="$SSH_OPTS -i $SSH_KEY"; fi
# push via scp
scp $SSH_OPTS "$BOOTSTRAP_SCRIPT" root@"$TARGET_HOST":/tmp/configure-ai-engine-inside-lxc.sh 2>&1 | head -n 20
if [[ -x /usr/bin/nvidia-smi ]]; then
	scp $SSH_OPTS /usr/bin/nvidia-smi root@"$TARGET_HOST":/tmp/nvidia-smi 2>&1 | head -n 20 || true
fi
ssh $SSH_OPTS root@"$TARGET_HOST" "bash /tmp/configure-ai-engine-inside-lxc.sh" 2>&1
echo "[configure] Done via ssh."
