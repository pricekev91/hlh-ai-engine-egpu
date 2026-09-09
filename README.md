# hlh-ai-engine-egpu-k80

Infrastructure-as-Code for the HLH shared AI inference engine (CUDA K80 eGPU variant).
Deploys a GPU-accelerated llama.cpp runtime as a Proxmox LXC container using the
CUDA backend (470 + 11.8) on an OCuLink Tesla K80.

## Executive Summary

This repository deploys and configures the **engine-egpu-k80** LXC on the HLH Proxmox
host `prox01` (192.168.1.10). It is a sibling of `hlh-ai-engine` (ROCm 890M) and
`hlh-ai-engine-egpu-vulkan` (Vulkan RX480) running the same shared AI inference workload
on discrete NVIDIA hardware.

- LXC 131, hostname `hlh-ai-engine-egpu-k80`, IP `192.168.1.31` (gw 192.168.1.1)
- CUDA backend via NVIDIA 470.256.02 + CUDA 11.8 on Tesla K80 dual GK210GL (2×12GB = 24GB board, cc 3.7 Kepler) via OCuLink on Minisforum DG2
- Dual GK210 chips at `c7:00.0` + `c8:00.0` (10de:102d) behind OCuLink switch `c5:00.0` (IOMMU 23/24), exposed as `nvidia0` + `nvidia1`
- llama.cpp `GGML_CUDA=ON` `ARCH=37` `FA=OFF` (Kepler, no flash attention), native web UI on port 80
- Model storage **same path host and CT** via bind mount: host `RaidZ1-6TB` ZFS dataset `RaidZ1-6TB/ai/models` at `/srv/ai/models` → LXC `/srv/ai/models` (shared with siblings, `775`, `zfs xattr,noacl`)
- LXC 8192 MB RAM, 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool, privileged `nesting=1,keyctl=1,fuse=1`, `onboot 1` (but single OCuLink slot — only one of LXC 130/131 can run)

> **24GB VRAM caveat:** K80 board is 2×12GB, but llama.cpp splits across `CUDA_VISIBLE_DEVICES=0,1`. Context window defaults to 32K (q4_0 KV ≈ 4GB). Use `k80-switch-model.sh` to adjust ctx/KV and see per-chip budgets. MTP draft `--spec-type draft-mtp` is unsupported on cc 3.7 (`CUBLAS_STATUS_ARCH_MISMATCH`); use `none` or `ngram` on K80.

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox `prox01`
- GPU passthrough for CUDA (`/dev/nvidia0`, `/dev/nvidia1`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools`, `/dev/nvidia-modeset`) via `cgroup2 c 195:*` + `c 51x:*` (dynamic 507/511) + bind mounts
- Host `nvidia_uvm` persistence (`/etc/modules-load.d/nvidia.conf` + `nvidia-uvm-devices.service` Before `pve-guests.service`, dynamic major via `grep nvidia-uvm /proc/devices`)
- Model storage bind-mount wiring (`--mp0 /srv/ai/models,mp=/srv/ai/models`)
- In-container CUDA 11.8 toolkit (ubuntu2204 repo on noble + jammy `libtinfo5` pin 100) + `libnvidia-compute-470`/`nvidia-utils-470` 470.256.02 reused from host branch + llama.cpp CUDA build (cc 3.7)

**Does not own:**
- Proxmox host kernel pin (that is `iac-hlh` / `proxmox-boot-tool`)
- Application logic or dashboard code (that is `TrashPanda`, `BrickCipher`, etc.)

## Quick Start

Deploy the K80 CUDA AI engine LXC on the Proxmox host (nukes 131, stops 130, reinstalls driver if needed):

```bash
./deploy-hlh-ai-engine-egpu-k80.sh
# --skip-host-driver to skip host 470/CUDA check (use after first reboot)
./deploy-hlh-ai-engine-egpu-k80.sh --skip-host-driver
```

Reconfigure an existing LXC via Ansible (no recreate):

```bash
./configure-hlh-ai-engine-egpu-k80.sh
./configure-hlh-ai-engine-egpu-k80.sh --host 192.168.1.31
```

Switch loaded models (inside LXC after deployment):

```bash
k80-switch-model.sh
# also at /srv/ai/models/k80-switch-model.sh (shared for MI60 reuse)
nvidia-smi -L; nvidia-smi
```

> Note: `hlh-ai-engine` (101), `hlh-ai-engine-egpu-vulkan` (130), and `hlh-ai-engine-egpu-k80` (131) share `/srv/ai/models`. You can run them concurrently only if they use different GPUs, but model file locking is not enforced. 130 and 131 share the single OCuLink slot — stop the other first: `pct stop 130 && pct start 131`.

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-ai-engine-egpu-k80.sh` creates the privileged LXC, wires CUDA passthrough (`/dev/nvidia*` — dynamic UVM major), and pushes the in-container bootstrap script. If host `nvidia` 470 not loaded, it blacklists `nouveau`, adds bullseye non-free + CUDA debian13 repo, installs `nvidia-tesla-470-driver=470.256.02-1~deb11u2` (DKMS), and reboots.
2. **Configuration**: `ansible/playbooks/hlh-ai-engine-egpu-k80.yml` (hosts `hlh_ai_engine_egpu_k80`) runs `ansible/files/configure-ai-engine-inside-lxc.sh` via `pct exec` or SSH.

## OpenTofu Module

For programmatic LXC creation via OpenTofu (bind mount, not storage volume):

```hcl
module "hlh_ai_engine_egpu_k80" {
  source = "./opentofu"
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  target_node         = "prox01"
  hostname            = "hlh-ai-engine-egpu-k80"
  vmid                = 131
  ip_cidr             = "192.168.1.31/24"
  memory              = 8192
  ostemplate          = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  # mp0 is bind mount: volume = "/srv/ai/models" mp = "/srv/ai/models"
}
# cgroup/mount for /dev/nvidia* is appended by deploy script post-create
```

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.31:80` |
| OpenAI-compatible base | `http://192.168.1.31:80/v1/` |
| Proxmox host | `prox01` 192.168.1.10 (Debian 13 trixie, kernel 7.0.14-11-pve) |
| Model storage | `/srv/ai/models` host (RaidZ1-6TB) ↔ `/srv/ai/models` LXC (bind mount `mp0`, same path) |
| GPU device | `/dev/nvidia0` (GK210 c7) + `/dev/nvidia1` (c8) + `nvidiactl` + `nvidia-uvm`/`-uvm-tools` (dynamic 507/511) + `nvidia-modeset` (195:254) — `c 195:*` + `c 51x:*` |
| eGPU | Tesla K80 GK210GL dual cc 3.7 2×12GB via OCuLink switch c5:00.0 (10de:102d rev a1) |
| Driver / CUDA | Host 470.256.02 + CUDA 11.8.0-1 (last for Kepler); CT toolkit from ubuntu2204 repo + jammy libtinfo5 pin 100 + `libnvidia-compute-470` 470.256.02-0ubuntu0.24.04.1 reused |
| Llama.cpp | `GGML_CUDA=ON` `CMAKE_CUDA_ARCHITECTURES=37` `FA=OFF` `FORCE_DMMV/MMQ=ON`, gcc-11 (CUDA 11.8 needs ≤11) |
| Default model | `Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf` (4.9GB on RaidZ1-6TB, 32K ctx q4_0) |
| LXC | 131, 8192 MB RAM, 12 cores, 64G rootfs RaidZ1-6TB, `nesting=1,keyctl=1,fuse=1` |
| Single slot | OCuLink c5:00.0 — LXC 130 (vulkan) and 131 (k80) cannot run together; deploy stops 130 |

## Repository Layout

```
hlh-ai-engine-egpu-k80/
├── deploy-hlh-ai-engine-egpu-k80.sh    # LXC creation + CUDA passthrough + bootstrap
├── configure-hlh-ai-engine-egpu-k80.sh # Ansible-based reconfiguration
├── ansible/
│   ├── inventories/hlh-ai-engine-egpu-k80.yml  # 192.168.1.31
│   ├── playbooks/hlh-ai-engine-egpu-k80.yml    # hosts: hlh_ai_engine_egpu_k80
│   └── files/
│       ├── configure-ai-engine-inside-lxc.sh   # v1.0.0-k80 CUDA 11.8 + 470
│       └── k80-switch-model.sh                 # v1.7.0-k80 standalone copy
├── opentofu/
│   ├── main.tf      # mp0 bind mount, no hostpci, cgroup via deploy
│   └── variables.tf # vmid 131, driver 470.256.02, CUDA 11.8.0-1
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── README.md
```

## GPU Backend Notes

**CUDA only.** This variant drops ROCm/HIP and Vulkan entirely:

- llama.cpp built with `GGML_CUDA=ON`, `GGML_VULKAN=OFF`, `GGML_HIP=OFF`, `GGML_CUDA_FA=OFF` (Kepler lacks FA), `CMAKE_CUDA_ARCHITECTURES=37`, `-allow-unsupported-compiler` + `gcc-11`
- CUDA toolkit 11.8 from `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/` (pinned `11.8.0-1`), jammy `libtinfo5`/`libncurses5` with pin `100`/`500`, `nvidia-utils-470`/`libnvidia-compute-470` `470.256.02-0ubuntu0.24.04.1` (reuses host 470 branch, holds `470` + `535` + `cuda-*`)
- Host driver: `nvidia-tesla-470-driver=470.256.02-1~deb11u2` (bullseye non-free) + `nvidia-modprobe -u -c 0` + `/etc/modules-load.d/nvidia.conf` (`nvidia`, `nvidia_uvm`, `nvidia_modeset`, `nvidia_drm`) + `nvidia-uvm-devices.service` with dynamic `UVM_MAJOR=$(grep nvidia-uvm /proc/devices | awk '{print $1}')`
- LXC needs `/tmp/nvidia-smi` pushed from host to fix noble's broken symlink `/usr/bin/nvidia-smi -> /usr/lib/nvidia-470/bin/nvidia-smi`
- OCuLink is PCIe — NOT hot-pluggable while LXC is running; K80 dual GK210 share switch, separate IOMMU 23/24

## llama.cpp Tuning Reference

Default llama-server flags (from systemd unit `ai-engine`):

| Flag | Default | Description |
|------|---------|-------------|
| `--model` | `/srv/ai/models/<ACTIVE>` | Model file (ACTIVE is first existing from `Mellum2-12B...`, `Qwen3-Coder-30B...`, etc., or any `*.gguf` on shared mount) |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `80` | Native web UI + API port |
| `--ctx-size` | `32768` (32K) | Context window (switch via `k80-switch-model.sh`) |
| `-ngl` | `99` | GPU offload layers (all) |
| `--batch-size` | `512` | Batch size |
| `--parallel` | `1` | Request parallelism |
| `--cache-type-k/v` | `q4_0` | KV cache quantization |
| `CUDA_VISIBLE_DEVICES` | `0,1` | Both GK210 chips |

Context size options (via `k80-switch-model.sh`):

| Option | ctx-size | Description |
|--------|----------|-------------|
| 1 | 98304 (96K) | Maximum — will OOM/spill even on 24GB |
| 2 | 73728 (72K) | Extended — spill |
| 3 | 65536 (64K) | Full — ~8GB KV q4_0 |
| 4 | 32768 (32K) | Recommended for 30B Q4 on K80 |
| 5 | 16384 (16K) | Quarter — minimal |
| 6 | 8192 (8K) | Minimal — max headroom |
| 7 | Custom | Enter manually |

KV cache VRAM estimates (per board, added to model weights):

| Context | q4_0 | q6_0 | q8_0 |
|---------|------|------|------|
| 64K | ~8 GB | ~12 GB | ~18 GB |
| 32K | ~4 GB | ~6 GB | ~9 GB |
| 16K | ~2 GB | ~3 GB | ~5 GB |
| 8K | ~1 GB | ~2 GB | ~3 GB |

> On K80 board 24GB: `30B Q4_K_M (~18GB) + 32K q4_0 (~4GB) = ~22GB` fits; `35B Q4 (~21GB) + 32K q4_0 (~4GB) = ~25GB` spills. MTP `draft-mtp` unsupported on cc 3.7.

## Health Checks & Service Lifecycle

| Check | Command |
|-------|---------|
| Service status | `systemctl status ai-engine` |
| Live health | `curl -s http://localhost:80/health` |
| Model info | `curl -s http://localhost:80/v1/models` |
| GPU usage | `nvidia-smi` ; `nvidia-smi -L` (expect 2 GPUs) |
| Logs | `journalctl -u ai-engine -f` |
| List CUDA devices | `nvidia-smi -L` (not `llama-server --list-devices` — that is Vulkan) |

`k80-switch-model.sh` waits up to 90×2s = 180s probing `/health` and aborting on `ActiveState=failed` / `NRestarts` bump.

## Governance

This repo is forked from `hlh-ai-engine-vulkan` (LXC 130) but is now CUDA K80 (LXC 131). Deployments consume pinned commits. See `checkpoint.md` for host/architecture resume point and `98_README.md` / HLH Agile Design Handbook for dependency map.
