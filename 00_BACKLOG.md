# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## GPU / CUDA (K80)

- Add GPU memory utilization monitoring script (`nvidia-smi` parsing + alerting) for K80 2×12GB board (per-chip via `nvidia-smi -L` + `CUDA_VISIBLE_DEVICES`)
- Add automatic model eviction when per-chip VRAM low (spillover detection via `nvidia-smi` + `dmesg` CUBLAS mismatch)
- Track OCuLink PCIe link width/speed + hotplug safety (NOT hot-pluggable while LXC running, switch c5:00.0)
- Track driver 470.256.02 EOL vs kernel 7.0 compat (DKMS, joanbm patch) — CUDA 11.8 is final for cc 3.7 Kepler (CUDA 12 drops Kepler)
- Evaluate 8GB LXC RAM sizing — build succeeds with `gcc-11` -j capped by `MemTotal` (1500MB/job), confirm 8192 is enough

## Model Management (shared /srv/ai/models same path host and CT)

- [DONE] Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf as default model (~54 tok/s vulkan eGPU, CUDA bench pp20 42.6 on K80)
- [DONE] Default model path: /srv/ai/models/Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf (4.9GB on RaidZ1-6TB, bind mount to LXC)
- Add model versioning system (pin specific GGUF files per deployment) — prefer 7B-14B for 8GB eGPU, 30B+ spills on K80 12GB per chip
- Add model download progress tracking and resume support (`/srv/ai/models/dl.sh` pattern from ROCm variant)
- Add model quality scoring after inference testing
- Document spillover for 30B/35B on K80 dual (24GB board but per-chip 12GB, `CUDA_VISIBLE_DEVICES=0,1` splits)

## LXC Lifecycle (131 K80)

- [DONE] Switched from native hostpci passthrough to cgroup device-allow + /dev/nvidia* bind-mount (Proxmox 9.x compatible, card-agnostic across 130/131)
- [DONE] Host nvidia-uvm persistence dynamic major (511/507) via `nvidia-uvm-devices.service` + `/etc/modules-load.d/nvidia.conf` (fixes CPU fallback after reboot)
- [DONE] `features fuse=1` alignment between `deploy` and `opentofu/main.tf`
- Add LXC snapshot before major model updates
- Add LXC resource quota enforcement (CPU, memory, I/O)
- Add LXC snapshot restore procedure

## Ansible Improvements

- Add ansible-lint to CI workflow
- Split configure-ai-engine-inside-lxc.sh into multiple Ansible roles (currently monolith 1.0.0-k80)
- Add idempotency tests for ansible playbook
- Add ansible-galaxy role packaging for reuse

## OpenTofu

- [DONE] `mp0` bind mount fix: `volume="/srv/ai/models"` `mp="/srv/ai/models"` (was `path`+`storage` new volume) — host and CT same path
- Add tofu variables for GPU PCI IDs (currently hardcoded via cgroup rules `c7:00.0`/`c8:00.0` + switch `c5:00.0`)
- Add tofu output for container IP and API endpoint (192.168.1.31)
- Add tofu state locking for multi-operator safety
- Migrate from telmate/proxmox to bpg/proxmox provider (align with hlh-docker)

## Networking (131)

- [DONE] LXC 131 hostname: hlh-ai-engine-egpu-k80, IP: 192.168.1.31, port 80
- Add DNS entry for engine API endpoint (k80: hlh-ai-engine-egpu-k80.local / 192.168.1.31)
- Add HTTPS/TLS termination on nginx reverse proxy
- Add rate limiting configuration for API endpoints
- Add API key authentication for external consumers

## Observability

- Add Prometheus metrics endpoint for inference latency (llama-server `/health`, `/metrics` when available)
- Add structured logging for llama-server (systemd `ai-engine`)
- Add request logging with model name and token count (k80-switch-model.sh already logs `nvidia-smi -L`)

## Deployment

- [DONE] Host driver 470.256.02 + CUDA 11.8.0-1 pinned (reuse 470 in CT via `libnvidia-compute-470` 470.256.02-0ubuntu0.24.04.1)
- Add pre-flight checks for GPU availability before deployment (verify GK210 10de:102d ×2, not Ellesmere/POLARIS10)
- Add dry-run / plan mode for deploy script
- Add rollback procedure for failed deployments
- Add CI checks for shell scripts (shellcheck)
