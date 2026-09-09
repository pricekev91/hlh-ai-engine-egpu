# hlh-ai-engine-egpu-vulkan

Infrastructure-as-Code for the HLH shared AI inference engine (Vulkan eGPU variant).
Deploys a GPU-accelerated llama.cpp runtime as a Proxmox LXC container using the
Vulkan backend (Mesa RADV) on an OCuLink eGPU.

## Executive Summary

This repository deploys and configures the **engine-egpu-vulkan** LXC on the HLH Proxmox
host `prox01` (192.168.1.10). It is a sibling of `hlh-ai-engine` (ROCm 890M) and
`hlh-ai-engine-vulkan` (Vulkan 890M iGPU) running the same shared AI inference workload
on discrete graphics.

- LXC 130, hostname `hlh-ai-engine-egpu-vulkan`, IP `192.168.1.30` (gw 192.168.1.1)
- Vulkan backend via Mesa RADV on AMD Ellesmere RX480 (gfx803 POLARIS10) 8GB via OCuLink on Minisforum DG2
- Both iGPU (890M gfx1150) and eGPU are visible inside LXC — selection via `vulkan-switch-model.sh --device`
- llama.cpp backend serving native web UI on port 80
- Model storage shared with siblings on `RaidZ1-6TB` ZFS pool (`/srv/ai/models`)
- LXC memory 8GB (discrete VRAM — no shared-memory APU requirement; vs 48GB on iGPU variant)

> **8GB VRAM caveat:** The RX480 has 8GB dedicated VRAM. Context window is 64K by default (q4_0 KV cache ≈ 0.5 GB). Use `vulkan-switch-model.sh` to adjust ctx-size and see spillover analysis.

## Repository Boundary

**Owns:**
- LXC lifecycle (create, configure, start) on Proxmox `prox01`
- GPU passthrough configuration for Vulkan (`/dev/dri` only — no `/dev/kfd`) — both GPUs visible
- Model storage mount wiring
- In-container Mesa Vulkan and llama.cpp installation (eGPU-tuned)

**Does not own:**
- Proxmox host configuration (that is `iac-hlh`)
- Application logic or dashboard code (that is `TrashPanda`, `BrickCipher`, etc.)

## Quick Start

Deploy the eGPU Vulkan AI engine LXC on the Proxmox host:

```bash
./deploy-hlh-ai-engine-egpu-vulkan.sh
```

Reconfigure an existing LXC via Ansible:

```bash
./configure-hlh-ai-engine-egpu-vulkan.sh
```

Switch loaded models (inside LXC after deployment):

```bash
vulkan-switch-model.sh
```

> Note: `hlh-ai-engine`, `hlh-ai-engine-vulkan`, and `hlh-ai-engine-egpu-vulkan` share `/srv/ai/models`. You can run them concurrently — they use different GPUs (APU vs eGPU) — but model file locking is not enforced.

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-ai-engine-egpu-vulkan.sh` creates the LXC, wires GPU
   passthrough (`/dev/dri` — both iGPU + eGPU visible), and pushes the in-container bootstrap script.
2. **Configuration**: `ansible/playbooks/hlh-ai-engine-egpu-vulkan.yml` configures
   services, runtime, and networking inside the container.

## OpenTofu Module

For programmatic LXC creation via OpenTofu:

```hcl
module "hlh_ai_engine_egpu_vulkan" {
  source = "./opentofu"
  pm_api_url         = var.pm_api_url
  pm_api_token_id    = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  target_node        = "prox01"
  hostname           = "hlh-ai-engine-egpu-vulkan"
  vmid               = 130
  # ... other variables (ip_cidr = "192.168.1.30/24", memory = 8192)
}
```

## Runtime Contract

| Item | Value |
|------|-------|
| API endpoint | `http://192.168.1.30:80` |
| OpenAI-compatible base | `http://192.168.1.30:80/v1/` |
| Proxmox host | `prox01` 192.168.1.10 |
| Model storage | `/srv/ai/models` (host mount, shared) |
| GPU device | `/dev/dri` bind-mount only (no `/dev/kfd`) — both iGPU+eGPU visible |
| eGPU | RX480 Ellesmere POLARIS10 gfx803 8GB via OCuLink (RADV) |
| Default model | Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf (spills on 8GB — see caveat) |
| LXC RAM | 8192 MB (vs 49152 on iGPU variant) |

## Repository Layout

```
hlh-ai-engine-egpu-vulkan/
├── deploy-hlh-ai-engine-egpu-vulkan.sh    # LXC creation + GPU passthrough + bootstrap
├── configure-hlh-ai-engine-egpu-vulkan.sh # Ansible-based reconfiguration
├── ansible/
│   ├── inventories/hlh-ai-engine-egpu-vulkan.yml
│   ├── playbooks/hlh-ai-engine-egpu-vulkan.yml
│   └── files/configure-ai-engine-inside-lxc.sh
├── opentofu/
│   ├── main.tf
│   └── variables.tf
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── README.md
```

## GPU Backend Notes

**Vulkan only.** This variant drops ROCm/HIP entirely:

- llama.cpp built with `GGML_VULKAN=ON`, `GGML_HIP=OFF`, `GGML_CUDA=OFF`
- Mesa Vulkan stack: `libvulkan1`, `libvulkan-dev`, `mesa-vulkan-drivers` (RADV),
  `vulkan-tools`, `glslc`
- RADV supports gfx803 (Polaris10 Ellesmere RX480) natively — no
  `HSA_OVERRIDE_GFX_VERSION` needed
- RADV also supports gfx1150 (890M iGPU) — both appear as `Vulkan0`/`Vulkan1`; use `vulkan-switch-model.sh` to pin
- GPU passthrough is `/dev/dri` only; `/dev/kfd` is ROCm-specific and not required
- OCuLink is PCIe — NOT hot-pluggable while LXC is running

## llama.cpp Tuning Reference

Default llama-server flags (from systemd unit):

| Flag | Default | Description |
|------|---------|-------------|
| `--model` | mounted GGUF path | Model file |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `80` | Native web UI + API port |
| `--ctx-size` | `65536` (64K) | Context window (switch via `vulkan-switch-model.sh`) |
| `-ngl` | `48` | GPU offload layers |
| `--batch-size` | `128` | Batch size for inference |
| `--parallel` | `1` | Request parallelism |
| `--cache-type-k` | `q4_0` | KV key cache quantization |
| `--cache-type-v` | `q4_0` | KV value cache quantization |
| `--spec-type` | `draft-mtp` | MTP speculative decoding (auto-detected for MTP models) |
| `--spec-draft-n-max` | `3` | MTP draft tokens |

Context size options (via `vulkan-switch-model.sh`):

| Option | ctx-size | Description |
|--------|----------|-------------|
| 1 | 98304 (96K) | Maximum — **will spill on 8GB** |
| 2 | 73728 (72K) | Extended — **will spill on 8GB** |
| 3 | 65536 (64K) | Full — **will spill on 8GB** |
| 4 | 32768 (32K) | Half — spills on 8GB with 30B models |
| 5 | 16384 (16K) | Quarter — recommended max for 8GB + 30B |
| 6 | 8192 (8K) | Minimal — recommended for 8GB eGPU |
| 7 | Custom | Enter manually |

KV cache VRAM estimates (added to model weights):

| Context | q4_0 | q6_0 | q8_0 |
|---------|------|------|------|
| 96K | ~12 GB | ~18 GB | ~24 GB |
| 72K | ~9 GB | ~14 GB | ~18 GB |
| 64K | ~8 GB | ~12 GB | ~18 GB |
| 32K | ~4 GB | ~6 GB | ~9 GB |
| 16K | ~2 GB | ~3 GB | ~5 GB |
| 8K | ~1 GB | ~2 GB | ~3 GB |

> On 8GB RX480: `30B Q4_K_M (~18GB) + 8K q4_0 (~1GB) = ~19GB` → spills ~11GB to RAM. Prefer 7B–14B models for full VRAM fit.

## Health Checks & Service Lifecycle

| Check | Command |
|-------|---------|
| Service status | `systemctl status ai-engine` |
| Live health | `curl -s http://localhost:80/health` |
| Model info | `curl -s http://localhost:80/v1/models` |
| GPU usage | `amdgpu_top` (or `vulkaninfo --summary`) |
| Logs | `journalctl -u ai-engine -f` |
| List Vulkan devices | `/opt/llama.cpp/build/bin/llama-server --list-devices` |

The `vulkan-switch-model.sh` script waits up to 30 seconds for the service to come
back up after a model switch, confirming `systemctl is-active --quiet ai-engine`.

## Governance

This repo is cloned from `hlh-ai-engine-vulkan` (LXC 120). Deployments consume pinned commits for
deterministic results. See the HLH Agile Design Handbook for the full architecture
and dependency map.
