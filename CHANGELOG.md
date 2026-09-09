# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
