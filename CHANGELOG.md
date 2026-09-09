# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-egpu] - 2026-08-26

### Added

- Fork from `hlh-ai-engine-vulkan` (LXC 120, 192.168.1.20) as `hlh-ai-engine-egpu-vulkan` (LXC 130, 192.168.1.30)
- OCuLink eGPU support: AMD Ellesmere RX480 (gfx803 POLARIS10) 8GB via OCuLink on Minisforum DG2
- Both iGPU (890M gfx1150) and eGPU visible inside LXC — selection via `vulkan-switch-model.sh --device`

### Changed

- LXC 130 `hlh-ai-engine-egpu-vulkan` 192.168.1.30/24 (gw 192.168.1.1) on `prox01` (192.168.1.10)
- LXC memory 2048 MB (vs 49152 on iGPU variant — discrete VRAM, no shared APU requirement)
- Swap 1024 MB, cores 12, rootfs 64GB on `RaidZ1-6TB` retained
- Deploy/configure scripts renamed with `-egpu-vulkan` suffix
- Ansible inventory `hlh_ai_engine_egpu_vulkan` host `192.168.1.30`
- OpenTofu `vmid=130`, `memory=2048`, `device.gpu=gfx803`, hostname `hlh-ai-engine-egpu-vulkan`
- Bootstrap `configure-ai-engine-inside-lxc.sh` v1.0.3-egpu: header updated for RX480 8GB, 8GB VRAM caveat
- README runtime contract updated for eGPU, prox01, and spillover guidance

---

## Upstream history (from hlh-ai-engine-vulkan)

## [1.0.2] - 2026-08

### Changed

- Use common systemd service name `ai-engine` (matches `hlh-ai-engine`) so the
  shared `hlh-switch-model.sh` works regardless of host/CT

## [1.0.1] - 2026-08

### Fixed

- Add `spirv-headers` and `glslang-tools` to base dependencies (Vulkan cmake
  configure failed on missing SPIRV-Headers config and glslangValidator)

## [1.0.0] - 2026-08

### Added

- Fork from `hlh-ai-engine` as `hlh-ai-engine-vulkan` (LXC 120, 192.168.1.20)
- Vulkan backend (Mesa RADV) replacing ROCm/HIP entirely

### Changed

- Rename deploy/configure scripts with `-vulkan` suffix
- Rename Ansible inventory and playbook to `hlh-ai-engine-vulkan`
- GPU passthrough reduced to `/dev/dri` only (no `/dev/kfd`, no cgroup 511 rule)
- llama.cpp built with `GGML_VULKAN=ON`, `GGML_HIP=OFF`, `GGML_CUDA=OFF`
- Remove ROCm repo/install, HIP tool checks, and ROCm systemd env vars
- Verification via `vulkaninfo`/`amdgpu_top` instead of `rocm-smi`
