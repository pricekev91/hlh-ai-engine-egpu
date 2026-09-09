# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## GPU / Vulkan (eGPU)

- Add GPU memory utilization monitoring script (`vulkaninfo`/`amdgpu_top` parsing + alerting) for RX480 8GB
- Add automatic model eviction when eGPU VRAM is low (spillover detection)
- Track OCuLink PCIe link width/speed + hotplug safety (NOT hot-pluggable while LXC running)
- Track Mesa/RADV version compatibility matrix across Proxmox kernel updates for gfx803 (Polaris)
- Evaluate 2GB LXC RAM sizing — confirm build succeeds (may need 4GB+ for llama.cpp cmake build)

## Model Management

- [DONE] Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf as default model (~54 tok/s on eGPU)
- [DONE] Default model path: /srv/ai/models/Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf (4.9GB on RaidZ1-6TB)
- Add model versioning system (pin specific GGUF files per deployment) — prefer 7B-14B for 8GB eGPU
- Add model download progress tracking and resume support
- Add model quality scoring after inference testing
- Document spillover guidance for 30B models on 8GB VRAM

## LXC Lifecycle

- [DONE] Switched from native hostpci passthrough to cgroup device-allow + /dev/dri bind-mount (Proxmox 9.x compatible, card-agnostic)
- [DONE] Fixed deploy script leading spaces causing "unable to parse config" errors
- Add LXC snapshot before major model updates
- Add LXC resource quota enforcement (CPU, memory, I/O)
- Add LXC snapshot restore procedure

## Ansible Improvements

- Add ansible-lint to CI workflow
- Split configure-ai-engine-inside-lxc.sh into multiple Ansible roles
- Add idempotency tests for ansible playbook
- Add ansible-galaxy role packaging for reuse

## OpenTofu

- Add tofu variables for GPU PCI IDs (currently hardcoded via cgroup rules)
- Add tofu output for container IP and API endpoint (192.168.1.30)
- Add tofu state locking for multi-operator safety
- Migrate from telmate/proxmox to bpg/proxmox provider (align with hlh-docker)

## Networking

- [DONE] LXC 130 hostname: hlh-ai-engine-egpu-vulkan, IP: 192.168.1.30, port 80
- Add DNS entry for engine API endpoint (egpu: hlh-ai-engine-egpu-vulkan.local / 192.168.1.30)
- Add HTTPS/TLS termination on nginx reverse proxy
- Add rate limiting configuration for API endpoints
- Add API key authentication for external consumers

## Observability

- Add Prometheus metrics endpoint for inference latency
- Add structured logging for llama-server
- Add request logging with model name and token count

## Deployment

- Add pre-flight checks for GPU availability before deployment (verify Ellesmere/POLARIS10)
- Add dry-run / plan mode for deploy script
- Add rollback procedure for failed deployments
- Add CI checks for shell scripts (shellcheck)
