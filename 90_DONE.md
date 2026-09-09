# DONE

This is what is already implemented and verified in this repository.

## LXC Deployment

- Direct Proxmox LXC creation via `deploy-hlh-ai-engine-egpu-vulkan.sh` (no OpenTofu required for initial setup)
- Privileged LXC 130 with hostname `hlh-ai-engine-egpu-vulkan` on `prox01` (192.168.1.10)
- 8 GiB RAM (down from 48 GiB — discrete 8GB VRAM, no APU shared memory), 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool
- Static IP assignment: `192.168.1.30/24` gw `192.168.1.1`
- Nesting and keyctl features enabled
- Prompt-before-redeploy guard prevents accidental LXC recreation

## GPU Passthrough

- AMD `/dev/dri` bind-mount for Vulkan device access — both iGPU (890M gfx1150) and eGPU (RX480 Ellesmere gfx803 POLARIS10 8GB via OCuLink) visible
- No `/dev/kfd` bind-mount (ROCm-only; not required by Vulkan)
- cgroup2 device allow rule: `c 226:* rwm` only
- GPU detected as Ellesmere [Radeon RX 470/480/570/580/590] (rev c7) — target RX480 8GB (gfx803)
- OCuLink PCIe — not hot-pluggable while LXC running

## Vulkan / Runtime

- Mesa Vulkan stack installed: `libvulkan1`, `libvulkan-dev`, `mesa-vulkan-drivers` (RADV), `vulkan-tools`, `glslc`
- llama.cpp built from HEAD with Vulkan only (`GGML_VULKAN=ON`, `GGML_HIP=OFF`, `GGML_CUDA=OFF`)
- llama-server native web UI on port 80 (no nginx)
- Model download skipped when `/srv/ai/models` mount already contains GGUF files
- MTP (Mixture of Parameter Transfer) auto-detect in switch-model.sh

## Model Management

- vulkan-switch-model.sh v1.9.0 with MTP auto-detect, ctx-size 96K support (service: ai-engine)
- Dynamic Vulkan device enumeration (`llama-server --list-devices` → Vulkan0/Vulkan1) with `--device` pinning
- Model storage: host `/srv/ai/models` bind-mounted to LXC `/srv/ai/models` (shared with hlh-ai-engine + hlh-ai-engine-vulkan)
- Default model pinned to `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` (spills on 8GB — use 8-16K ctx + q4_0)
- VRAM spillover analysis with headroom calculation and confirmation prompt
- MTP models detected by filename (case-insensitive 'MTP' match)
- Atomic ExecStart rewrite via awk (no sed fragility)
- Startup wait loop + web UI URL confirmation after model switch

## Networking

- llama-server native web UI + API on port 80 inside LXC
- OpenAI-compatible API at port 80/v1/
- Endpoint `http://192.168.1.30:80` on prox01

## Ansible Configuration

- Ansible inventory: `ansible/inventories/hlh-ai-engine-egpu-vulkan.yml` (host 192.168.1.30)
- Playbook: `ansible/playbooks/hlh-ai-engine-egpu-vulkan.yml` (hosts: hlh_ai_engine_egpu_vulkan)
- Bootstrap script: `ansible/files/configure-ai-engine-inside-lxc.sh` (v1.0.3-egpu)
- SSH key-based auth: `~/.ssh/id_ed25519`
- Reconfiguration via `configure-hlh-ai-engine-egpu-vulkan.sh` with `--host` and `--offline` flags

## OpenTofu Provisioning

- Proxmox provider: `telmate/proxmox >= 2.7.2`
- LXC resource `hlh_ai_engine_egpu_vulkan` with `vmid=130`, `memory=8192`, `gpu=gfx803`
- Variables for API URL, token auth, network (192.168.1.30/24), and storage (RaidZ1-6TB)
- GPU passthrough (cgroup allow + mount entries) documented for manual `pct set` path

## Configuration Scripts

- `deploy-hlh-ai-engine-egpu-vulkan.sh` - Full LXC creation, GPU passthrough (both GPUs visible), bootstrap
- `configure-hlh-ai-engine-egpu-vulkan.sh` - Ansible-based reconfiguration with host/offline flags

## Service Lifecycle

- Systemd auto-restart on failure (`Restart=on-failure`, `RestartSec=10`)
- `vulkan-switch-model.sh` waits up to 30 seconds for service to come back up
- `vulkaninfo` and `llama-server --version` verification in bootstrap
- 8GB VRAM caveat documented throughout

## Cloned From

- Forked from `hlh-ai-engine-vulkan` LXC 120 (gfx1150) — see its 90_DONE.md for upstream history
