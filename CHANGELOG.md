# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0-egpu] - 2026-09-24

### Changed

- **Repo renamed** `hlh-ai-engine-v100` → `hlh-ai-engine-egpu` — named for the OCuLink slot, not the card (card may change; slot IP is stable).
- **IP** `192.168.1.31` → `192.168.1.11` — new slot-based scheme: `.10` host, `.11` OCuLink eGPU workhorse, `.12+` iGPU engines.
- **Hostname** `hlh-ai-engine-v100` → `hlh-ai-engine-egpu`; switch helper `v100-switch-model.sh` → `egpu-switch-model.sh`.
- Scripts renamed `deploy-/configure-hlh-ai-engine-egpu.sh`. VMID stays `131`. Tesla V100 32GB card unchanged.

## [2.1.0-v100] - 2026-09-24

### Fixed

- **Host kernel pin**: `proxmox-kernel-6.14.11-9-pve` pinned LTS for `R580` (Volta). `7.0.14-11/17-pve` (`6.17`) and `6.5.13-5-pve` break `550/580 closed` (`__vm_flags`/`proc_ops`/`dma_is_direct`/`in_irq`) and `6.5` has `No route` on this board (`2086-071E`). `6.14` validated with `Tesla 580.65.06` `CUDA 13.0` host + `12.8` CT.
- **Driver**: `R580 Tesla 580.65.06` via `.run --dkms --install-libglvnd` on `6.14` (last for `Volta sm70`, `CUDA 12.8` final). `580.65.06` not in `trixie non-free`/`CUDA repo` (which has `590+` dropping Volta) - deploy now `wget` Tesla `.run` for `580` branch, `apt` for `550`. `UVM` major `508` (580) vs `507` (470) added to `lxc.cgroup2`.
- **CT CUDA**: `cuda-toolkit-12-8` + `libnvidia-compute-580`/`nvidia-utils-580` from `ubuntu2404` (was `12.4/550`). `11.8/470` path kept for legacy `6.5` fallback, `gcc-13` for `12.8` (no jammy `libtinfo5`), `LD_LIBRARY_PATH` + `libnvidia-ml.so.580.65.06` symlink, `cgroup2` `c 508:*` added.
- **Build fix**: `gcc-11` auto-installed for `CUDA 11.8` legacy path; `CUDA 12.8` uses `gcc-13` native, `update-alternatives` `gcc-11` handling retained.

## [2.0.0-v100] - 2026-09-23

### Changed

- **Refactor K80 -> V100**: Renamed repo `hlh-ai-engine-k80` -> `hlh-ai-engine-v100` (LXC 131 same ID 192.168.1.31, hostname `hlh-ai-engine-v100`). V100 is single `GV100GL PG500-216 32GB cc 7.0 Volta` at `0000:c5:00.0` via GPP `00:03.1` OCuLink (was K80 dual GK210 `10de:102d` c7/c8 2x12GB cc 3.7). IOMMU 20 single GPU.
- **CUDA backend**: `GGML_CUDA=ON` `ARCH=70` `FA=ON` (Volta supports FA) vs K80 `ARCH=37 FA=OFF`. Driver `550.163.01-2` (trixie) + CUDA `12.4.1` from `ubuntu2404` repo (R580 580.65.06 is last for Volta, CUDA 12.8/12.9 final; trixie stable currently 550 - override via `NVIDIA_DRIVER_VERSION` env).
- **Passthrough**: single `/dev/nvidia0` + `nvidiactl` + `nvidia-uvm` (was dual `nvidia0`+`nvidia1`). `chmod 755` for `/srv/ai/models` (was `775`, root-managed homelab).
- **Scripts**: `deploy-hlh-ai-engine-v100.sh` (was k80), `configure-hlh-ai-engine-v100.sh`, `ansible` `hlh_ai_engine_v100` hosts, `opentofu` `hlh_ai_engine_v100` resource, `v100-switch-model.sh` (was k80) single-GPU 32GB budget, `configure-ai-engine-inside-lxc.sh` v1.0.0-v100-cuda.

## [1.1.0-k80] - 2026-09-09

### Fixed

- **nvidia-uvm**: `nvidia-uvm-devices.service` now dynamic `UVM_MAJOR=$(grep nvidia-uvm /proc/devices | awk '{print $1}')` (511 on 7.0, 507 on older) instead of hardcoded `507`; runtime fallback `mknod c $UVM_MAJOR` + `chmod 666` prevents CPU fallback after reboot/kernel bump.
- **CUDA bootstrap**: noble 24.04 LXC reuses host 470 branch (`libnvidia-compute-470=470.256.02-0ubuntu0.24.04.1`, last for Kepler cc 3.7, holds `470` + `535` + `cuda-*`), ubuntu2204 CUDA 11.8 repo with jammy `libtinfo5` pin `100`/`500` (only libtinfo5, not whole jammy), `--no-install-recommends` `cuda-nvcc-11-8` etc. first, fail-fast if toolkit absent (no silent `apt-get download`).
- **Model storage**: clarified host `RaidZ1-6TB/ai/models` at `/srv/ai/models` ↔ LXC `/srv/ai/models` same path via `--mp0 /srv/ai/models,mp=/srv/ai/models` (bind mount, not storage volume). Bootstrap `mkdir -p` is no-op when already mounted.
- **OpenTofu**: `mp0` changed to bind mount `volume="/srv/ai/models"` `mp="/srv/ai/models"` (was `path`+`storage` new volume), `features fuse=1` aligned with `deploy --features nesting=1,keyctl=1,fuse=1`, comments updated for K80 dynamic UVM.

### Changed

- Docs: `README` rewritten for K80 (LXC 131, IP 192.168.1.31, CUDA 11.8+470, GK210 dual 24GB, `/dev/nvidia*`, `k80-switch-model.sh`), `90_DONE` aligned, `opentofu/variables.tf` docs kept but `mp0` comment fixed.

## [1.0.0-k80] - 2026-08-26

### Added

- Fork for `hlh-ai-engine-egpu-k80` LXC 131 `hlh-ai-engine-egpu-k80` 192.168.1.31/24 on `prox01` (192.168.1.10) — Tesla K80 GK210GL dual 2×12GB cc 3.7 via OCuLink `c5:00.0` (`c7:00.0` + `c8:00.0` 10de:102d, IOMMU 23/24)
- CUDA 11.8.0-1 + driver 470.256.02 pinned (last for Kepler, CUDA 12 drops cc 3.7), `GGML_CUDA=ON` `ARCH=37` `FA=OFF`, `gcc-11`, `CUDA_VISIBLE_DEVICES=0,1`, `k80-switch-model.sh` v1.7.0-k80 (`/srv/ai/models/k80-switch-model.sh` for MI60 reuse)
- Host UVM persistence `nvidia-uvm-devices.service` + `/etc/modules-load.d/nvidia.conf`, `lxc.cgroup2` `195:*` + `51x:*` and `/dev/nvidia*` mounts

### Changed

- LXC 131 `hlh-ai-engine-egpu-k80` 192.168.1.31 (vs 130 vulkan), `memory=8192`, `cores=12`, `rootfs 64G RaidZ1-6TB`, `mp0` bind to `/srv/ai/models`
- Bootstrap `configure-ai-engine-inside-lxc.sh` v1.0.0-k80: CUDA 11.8 + 470 reuse, `nvidia-smi` push via `/tmp/nvidia-smi`

---

## Upstream history (from hlh-ai-engine-vulkan)

## [1.0.0-egpu] - 2026-08-26 (vulkan RX480)

### Added

- Fork from `hlh-ai-engine-vulkan` (LXC 120, 192.168.1.20) as `hlh-ai-engine-egpu-vulkan` (LXC 130, 192.168.1.30)
- OCuLink eGPU support: AMD Ellesmere RX480 (gfx803 POLARIS10) 8GB via OCuLink

... (prior 1.0.2/1.0.1/1.0.0 Vulkan entries retained as upstream history)
