# DONE

This is what is already implemented and verified in this repository.

## LXC Deployment

- Direct Proxmox LXC creation via `deploy-hlh-ai-engine-egpu-k80.sh` (no OpenTofu required for initial setup, but OpenTofu module exists)
- Privileged LXC 131 with hostname `hlh-ai-engine-egpu-k80` on `prox01` (192.168.1.10) — Debian 13 trixie, kernel 7.0.14-11-pve
- 8192 MB RAM, 12 cores, 64 GiB rootfs on `RaidZ1-6TB` pool, `nesting=1,keyctl=1,fuse=1`, `onboot 1` (single OCuLink slot — stops 130 if running)
- Static IP `192.168.1.31/24` gw `192.168.1.1` `vmbr0`
- Prompt-before-redeploy guard `confirm_existing_lxc_delete`
- Model storage **same path host and CT**: host ZFS `RaidZ1-6TB/ai/models` at `/srv/ai/models` (`775`, `zfs xattr,noacl`) bind-mounted via `--mp0 /srv/ai/models,mp=/srv/ai/models` → LXC `/srv/ai/models` (OpenTofu `mp0 { volume="/srv/ai/models" mp="/srv/ai/models" }`)

## GPU Passthrough (K80 CUDA)

- NVIDIA Tesla K80 GK210GL dual 2×12GB (10de:102d rev a1) via OCuLink switch `c5:00.0` with chips `c7:00.0` + `c8:00.0` (IOMMU 23/24 separate) detected via `lspci -nn -D | grep 10de:102d`
- Host driver pinned `470.256.02` (last for Kepler cc 3.7, CUDA 12 drops Kepler) — `nvidia-tesla-470-driver=470.256.02-1~deb11u2` from bullseye non-free + CUDA debian13 repo, `nouveau` blacklisted, `update-initramfs -u`, reboot
- Host UVM persistence: `/etc/modules-load.d/nvidia.conf` (`nvidia`, `nvidia_uvm`, `nvidia_modeset`, `nvidia_drm`) + `nvidia-uvm-devices.service` `Before=pve-guests.service` with dynamic `UVM_MAJOR=$(grep nvidia-uvm /proc/devices | awk '{print $1}')` → `mknod c $UVM_MAJOR 0/1` + `chmod 666` (fixes `507` vs `511` major drift across kernels, avoids CPU fallback)
- LXC passthrough via cgroup + bind-mount (no `hostpci`): `c 195:* rwm` (`nvidia0/1/ctl/modeset`) + `c 507:*` + `c 510:*` + `c 511:*` (covers all UVM majors) and `lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file` (×6 for `nvidia0`, `nvidia1`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`, `nvidia-modeset`)
- `nvidia-smi 470.256.02` verified `2 GPUs` `3324MiB` (Mellum 12B) / `11022MiB` (Qwen35B) after bootstrap

## CUDA / Runtime

- CUDA toolkit 11.8.0-1 pinned (last with cc 3.7) from `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/` (ubuntu2204 repo reused on noble 24.04 LXC) with jammy `libtinfo5`/`libncurses5` pinned `100`/`500` (only `libtinfo5` pulled, not whole jammy), `--no-install-recommends` `cuda-nvcc-11-8` etc. fallback to `cuda-toolkit-11-8`
- CT userspace reuses host 470 branch: `libnvidia-compute-470=470.256.02-0ubuntu0.24.04.1` + `nvidia-utils-470=470.256.02-0ubuntu0.24.04.1` (hold `470` + `535` + `cuda-*` to avoid 535 transitional), `LD_LIBRARY_PATH=/usr/local/cuda/lib64`, `/etc/profile.d/cuda.sh`, `PATH=/usr/local/cuda/bin`
- Noble's broken `/usr/bin/nvidia-smi -> /usr/lib/nvidia-470/bin/nvidia-smi` fixed by `pct push /usr/bin/nvidia-smi /tmp/nvidia-smi` → `cp /tmp/nvidia-smi /usr/bin/nvidia-smi` + `libnvidia-ml.so.1` symlink to `470.256.02`
- llama.cpp built from HEAD with CUDA only (`GGML_CUDA=ON`, `CMAKE_CUDA_ARCHITECTURES=37`, `GGML_CUDA_FA=OFF`, `FORCE_DMMV/MMQ=ON`, `VULKAN/HIP=OFF`, `-allow-unsupported-compiler`, `gcc-11`/`g++-11` via `update-alternatives`, `CUDAHOSTCXX=11`)
- llama-server native web UI on port 80 (no nginx), systemd `ai-engine` `Restart=on-failure RestartSec=10`, `WorkingDirectory=/opt/llama.cpp/build/bin`, `Environment=PATH/LD_LIBRARY_PATH/CUDA_VISIBLE_DEVICES=0,1`, flags `--model /srv/ai/models/<ACTIVE> --host 0.0.0.0 --port 80 --ctx-size 32768 -ngl 99 --batch-size 512 --parallel 1 --cache-type-k q4_0 --cache-type-v q4_0`
- Model selection from shared mount: `DEFAULT_MODEL_FILE=Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf` → `PREFERRED_MODELS` → any `*.gguf` via `find`, active via `grep -- --model` in switcher

## Model Management

- `k80-switch-model.sh` v1.7.0-k80 (single source: `/usr/local/bin/k80-switch-model.sh` + `/srv/ai/models/k80-switch-model.sh` for MI60 reuse) — banner VRAM 2×12GB=24GB, ctx 96K/72K/64K/32K/16K/8K, KV q8_0/q6_0/q4_0, MTP/ngram/none (MTP draft `draft-mtp` unsupported on cc 3.7 → `CUBLAS_STATUS_ARCH_MISMATCH`, use `none`/`ngram`), `CUDA_VISIBLE_DEVICES` display, `nvidia-smi -L` verify, `rewrite_execstart` via `awk` atomic, health probe `curl http://127.0.0.1:80/health` 90×2s
- Host `/srv/ai/models` ↔ LXC `/srv/ai/models` same path (bind mount, not storage volume)

## Networking

- llama-server native web UI + API on port 80 inside LXC, OpenAI-compatible at `80/v1/`, endpoint `http://192.168.1.31:80` on prox01

## Ansible Configuration

- Ansible inventory: `ansible/inventories/hlh-ai-engine-egpu-k80.yml` (host `192.168.1.31`, `ansible_host: 192.168.1.31`)
- Playbook: `ansible/playbooks/hlh-ai-engine-egpu-k80.yml` (hosts `hlh_ai_engine_egpu_k80`, `ansible.builtin.script: ../files/configure-ai-engine-inside-lxc.sh`, `HLH_OFFLINE`)
- Bootstrap script: `ansible/files/configure-ai-engine-inside-lxc.sh` v1.0.0-k80 (CUDA 11.8 + 470 reuse, dynamic UVM)
- Standalone switcher copy: `ansible/files/k80-switch-model.sh` (289 lines, single source)
- SSH key-based auth: `~/.ssh/id_ed25519`, reconfiguration via `configure-hlh-ai-engine-egpu-k80.sh` with `--host`/`--offline`

## OpenTofu Provisioning

- Proxmox provider `telmate/proxmox >= 2.7.2`, `prox01` `https://192.168.1.10:8006/` `pm_tls_insecure true`
- LXC resource `hlh_ai_engine_egpu_k80` `vmid=131` `memory=8192` `cores=12` `swap=1024` `ostemplate=ubuntu-24.04-standard_24.04-2_amd64.tar.zst` `storage=RaidZ1-6TB` `rootfs 64G` `features nesting/keyctl/fuse`
- Network `vmbr0` `192.168.1.31/24` `gw 192.168.1.1`
- `mp0` bind mount `volume="/srv/ai/models"` `mp="/srv/ai/models"` (deploy uses `--mp0 /srv/ai/models,mp=/srv/ai/models`)
- Variables for `pm_api_*`, `target_node`, `hostname`, `vmid`, `ostemplate`, `storage`, `rootfs_size_gb`, `cores`, `memory`, `swap`, `bridge`, `ip_cidr`, `gateway`, `network_tag`, `lxc_root_password`, `egpu_pci_address=0000:c5:00.0`, `nvidia_driver_version=470.256.02-1~deb11u2`, `cuda_version=11.8.0-1`, `description`, `model_mount_path=/srv/ai/models`, `model_storage=RaidZ1-6TB`
- GPU passthrough (cgroup + mount) documented for manual `pct set` path, not HostPCI
- Outputs `lxc_vmid`, `lxc_hostname`

## Configuration Scripts

- `deploy-hlh-ai-engine-egpu-k80.sh` — Host 470/CUDA pin + dynamic UVM service + privileged LXC 131 + CUDA passthrough + `pct push` bootstrap
- `configure-hlh-ai-engine-egpu-k80.sh` — Ansible reconfiguration with `--host`/`--offline`

## Service Lifecycle

- Systemd `ai-engine` `Restart=on-failure RestartSec=10`, `k80-switch-model.sh` health probe `curl -fsS -m 3 http://127.0.0.1:80/health` with `NRestarts`/`ActiveState` check, `nvidia-smi -L` + `llama-server --version` verification

## Cloned From

- Forked from `hlh-ai-engine-vulkan` LXC 130 (gfx803) then diverged to CUDA K80 LXC 131 — see upstream 90_DONE for Vulkan history, now K80 is CUDA-only
