# hlh-ai-engine-v100

Infrastructure-as-Code for the HLH shared AI inference engine (CUDA V100 Volta eGPU variant).
Deploys a GPU-accelerated llama.cpp runtime as a Proxmox LXC container using the
CUDA backend (580 + 12.8, sm70) on an OCuLink Tesla V100 32GB (6.14 LTS kernel).

## Executive Summary

This repository deploys and configures the **engine-v100** LXC on the HLH Proxmox
host `prox01` (192.168.1.10). It is a sibling of `hlh-ai-engine` (ROCm 890M) and
`hlh-ai-engine-egpu-vulkan` (Vulkan RX480) - now refactored from `hlh-ai-engine-k80` (K80 dual Kepler) to single Volta V100.

- LXC 131, hostname `hlh-ai-engine-v100`, IP `192.168.1.31` (gw 192.168.1.1)
- CUDA backend via NVIDIA 580.65.06 (R580 last for Volta) + CUDA 12.8 on Tesla V100 GV100GL PG500-216 (32GB HBM2, cc 7.0 Volta) via OCuLink c5:00.0 (was dual GK210 2x12GB)
- Single GV100 at `c5:00.0` (10de:1df0 rev a1) via GPP `00:03.1` OCuLink x4 (currently 8GT/s x2), IOMMU 20, exposed as `nvidia0`
- llama.cpp `GGML_CUDA=ON` `ARCH=70` `FA=ON` (Volta supports Flash Attention), native web UI on port 80
- Model storage **same path host and CT** via bind mount: host `RaidZ1-6TB` ZFS dataset `RaidZ1-6TB/ai/models` at `/srv/ai/models` → LXC `/srv/ai/models` (`755`, `root` managed, homelab, `zfs xattr,noacl`)
- LXC 8192 MB RAM, 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool, privileged `nesting=1,keyctl=1,fuse=1`, `onboot 1` (single OCuLink slot — only one of LXC 130/131 can run)

> **32GB VRAM:** V100 32GB is single-GPU (unlike K80 2x12GB). llama.cpp uses `CUDA_VISIBLE_DEVICES=0` (single). Context window defaults to 32K (q4_0 KV ≈ 4GB) - 32GB allows 70B Q4 + 32K, or 35B Q4 + 64K. Use `v100-switch-model.sh` to adjust ctx/KV. MTP draft still experimental on Volta; use `none` or `ngram`.

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox `prox01` (pinned `proxmox-kernel-6.14.11-9-pve` for R580)
- GPU passthrough for CUDA (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools`, `/dev/nvidia-modeset`) via `cgroup2 c 195:*` + `c 508:*` (R580) + `c 507:*` + `c 510/511:*` (dynamic UVM major)
- Host `nvidia_uvm` persistence (`/etc/modules-load.d/nvidia.conf` + `nvidia-uvm-devices.service` Before `pve-guests.service`, dynamic major `508` for 580)
- Model storage bind-mount wiring (`--mp0 /srv/ai/models,mp=/srv/ai/models`)
- In-container CUDA 12.8 toolkit (ubuntu2404 repo) + `libnvidia-compute-580`/`nvidia-utils-580` 580.65.06 + llama.cpp CUDA build (cc 7.0)

**Does not own:**
- Proxmox host kernel pin (that is `iac-hlh` / `proxmox-boot-tool`)
- Application logic or dashboard code

## Quick Start

Deploy the V100 CUDA AI engine LXC on the Proxmox host (nukes 131, stops 130, installs driver if needed):

```bash
./deploy-hlh-ai-engine-v100.sh
# --skip-host-driver to skip host 550/CUDA check (use after first reboot)
./deploy-hlh-ai-engine-v100.sh --skip-host-driver
```

Reconfigure an existing LXC via bash (no recreate, no ansible):

```bash
./configure-hlh-ai-engine-v100.sh
./configure-hlh-ai-engine-v100.sh --host 192.168.1.31
./configure-hlh-ai-engine-v100.sh --via-ssh --host 192.168.1.31
```

Switch loaded models (inside LXC after deployment):

```bash
v100-switch-model.sh
# also at /srv/ai/models/v100-switch-model.sh
nvidia-smi -L; nvidia-smi
```

> Note: `hlh-ai-engine` (101), `hlh-ai-engine-egpu-vulkan` (130), and `hlh-ai-engine-v100` (131) share `/srv/ai/models`. 130 and 131 share the single OCuLink slot — stop the other first: `pct stop 130 && pct start 131`.

## Deployment Model

Two bash scripts only (no ansible/opentofu):

1. **Provisioning**: `deploy-hlh-ai-engine-v100.sh` creates the privileged LXC, wires CUDA passthrough (`/dev/nvidia*` — single GV100), and pushes the configuration script. If host `nvidia` driver not loaded, it blacklists `nouveau`, ensures trixie non-free + CUDA debian13 repo, and installs `R580 Tesla 580.65.06` via `.run --dkms` (6.14 LTS kernel, Volta last) or `550` on `6.5` via DKMS. Last driver for Volta is R580 (580.65.06) with CUDA 12.8/12.9 - trixie stable has 550, 590+ drops Volta; use `580.65.06` Tesla .run on `6.14`.
2. **Configuration**: `configure-hlh-ai-engine-v100.sh` - when run on host it pushes itself into the LXC via `pct exec`/`ssh` and re-runs with `--bootstrap-inside`; that flag runs the embedded bootstrap (CUDA toolkit + llama.cpp `sm70 FA ON` + `v100-switch-model.sh` generation). No separate inside file.

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.31:80` |
| OpenAI-compatible base | `http://192.168.1.31:80/v1/` |
| Proxmox host | `prox01` 192.168.1.10 (Debian 13 trixie, kernel `6.14.11-9-pve` pinned, `R580` LTS) |
| Model storage | `/srv/ai/models` host (RaidZ1-6TB) ↔ `/srv/ai/models` LXC (bind mount `mp0`, same path, 755 root) |
| GPU device | `/dev/nvidia0` (GV100 c5:00.0) + `nvidiactl` + `nvidia-uvm`/`-uvm-tools` (dynamic `508` for 580) + `nvidia-modeset` (195:254) — `c 195:*` + `c 508:*` |
| eGPU | Tesla V100 GV100GL 32GB cc 7.0 via OCuLink c5:00.0 (10de:1df0 rev a1) - single GPU via GPP 00:03.1 x4 (8GT/s x2) |
| Driver / CUDA | Host `580.65.06` `CUDA 13.0` (R580 last for Volta, CC 7.0); CT `CUDA 12.8` `libnvidia-compute-580`/`nvidia-utils-580` from `ubuntu2404` (12.8 final sm70) |
| Llama.cpp | `GGML_CUDA=ON` `CMAKE_CUDA_ARCHITECTURES=70` `FA=ON` `FORCE_DMMV/MMQ=ON`, `gcc-13` (`CUDA 12.8` needs `≤13`) |
| Default model | `Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf` (4.9GB on RaidZ1-6TB, 32K ctx q4_0) |
| LXC | 131, 8192 MB RAM, 12 cores, 64G rootfs RaidZ1-6TB, `nesting=1,keyctl=1,fuse=1` |
| Single slot | OCuLink c5:00.0 — LXC 130 (vulkan) and 131 (v100) cannot run together; deploy stops 130 |

## Repository Layout

```
hlh-ai-engine-v100/
├── deploy-hlh-ai-engine-v100.sh    # Provision: LXC creation + CUDA passthrough + bootstrap (bash)
├── configure-hlh-ai-engine-v100.sh # Configuration: host wrapper + embedded bootstrap --bootstrap-inside (bash only)
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── README.md
```

## GPU Backend Notes

**CUDA only (Volta).** This variant is CUDA sm70:

- llama.cpp built with `GGML_CUDA=ON`, `GGML_VULKAN=OFF`, `GGML_HIP=OFF`, `GGML_CUDA_FA_ALL_QUANTS=ON` (Volta supports FA), `CMAKE_CUDA_ARCHITECTURES=70`, `FORCE_DMMV/MMQ`, `gcc-13`
- CUDA toolkit `12.8` from `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/` (pinned `12.8.0-1`), `nvidia-utils-580`/`libnvidia-compute-580` `580.65.06` (R580 last for Volta, `gcc-13` compatible, no `libtinfo5` jammy hack)
- Host driver: `Tesla R580 580.65.06` via `.run --dkms` on `proxmox-kernel-6.14.11-9-pve` (LTS, validated for `V100`); `nvidia-modprobe -u -c 0` + `/etc/modules-load.d/nvidia.conf` (`nvidia nvidia_uvm nvidia_modeset nvidia_drm`) + `nvidia-uvm-devices.service` `Before pve-guests` dynamic `UVM_MAJOR=508` (580) vs `507` (470)
- `7.0.14-11-pve`/`6.17` breaks `550/580 closed` `__vm_flags`/`proc_ops`/`dma_is_direct` - stay on `6.14` LTS until NVIDIA rebases. `6.5.13-5-pve` also broken on this board (`No route`). OCuLink `c5:00.0` `00:03.1` `IOMMU 20` single `GV100`.
- OCuLink is PCIe — NOT hot-pluggable while LXC is running; V100 single GPU IOMMU 20 at `00:03.1` GPP

## llama.cpp Tuning Reference

Default llama-server flags (from systemd unit `ai-engine`):

| Flag | Default | Description |
|------|---------|-------------|
| `--model` | `/srv/ai/models/<ACTIVE>` | Model file |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `80` | Native web UI + API port |
| `--ctx-size` | `32768` (32K) | Context window (switch via `v100-switch-model.sh`) |
| `-ngl` | `99` | GPU offload layers (all) |
| `--batch-size` | `512` | Batch size |
| `--parallel` | `1` | Request parallelism |
| `--cache-type-k/v` | `q4_0` | KV cache quantization |
| `CUDA_VISIBLE_DEVICES` | `0` | Single GV100 |

Context size options (via `v100-switch-model.sh`):

| Option | ctx-size | Description |
|--------|----------|-------------|
| 1 | 98304 (96K) | Maximum — 12GB KV q4_0, may spill |
| 2 | 73728 (72K) | Extended |
| 3 | 65536 (64K) | Full — ~8GB KV q4_0 |
| 4 | 32768 (32K) | Recommended for 30-35B Q4 on V100 32GB |
| 5 | 16384 (16K) | Quarter |
| 6 | 8192 (8K) | Minimal |
| 7 | Custom | Enter manually |

KV cache VRAM estimates (per board, added to model weights):

| Context | q4_0 | q6_0 | q8_0 |
|---------|------|------|------|
| 64K | ~8 GB | ~12 GB | ~18 GB |
| 32K | ~4 GB | ~6 GB | ~9 GB |
| 16K | ~2 GB | ~3 GB | ~5 GB |
| 8K | ~1 GB | ~2 GB | ~3 GB |

> On V100 32GB: `35B Q4_K_M (~21GB) + 32K q4_0 (~4GB) = ~25GB` fits comfortably; `70B Q4_K_M (~39GB) exceeds` needs quantization or 24K. V100 has more headroom than K80.

## Health Checks & Service Lifecycle

| Check | Command |
|-------|---------|
| Service status | `systemctl status ai-engine` |
| Live health | `curl -s http://localhost:80/health` |
| Model info | `curl -s http://localhost:80/v1/models` |
| GPU usage | `nvidia-smi` ; `nvidia-smi -L` (expect 1 GPU) |
| Logs | `journalctl -u ai-engine -f` |
| List CUDA devices | `nvidia-smi -L` |

`v100-switch-model.sh` waits up to 90×2s = 180s probing `/health` and aborting on `ActiveState=failed` / `NRestarts` bump.

## Governance

This repo is forked from `hlh-ai-engine-k80` (LXC 131) but is now CUDA V100 (LXC 131, same ID). Deployments consume pinned commits. K80 was EOL Kepler cc 3.7 - V100 Volta cc 7.0 is significantly faster (FA, Tensor Cores). See `CHANGELOG.md` for host/architecture resume point.
