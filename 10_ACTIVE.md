# TODO

Active items in progress. These are the current focus areas.

## Active (K80 LXC 131 CUDA 11.8 + 470)

- [x] ✅ Host driver 470.256.02 + CUDA 11.8 pinned (last for Kepler cc 3.7) — `nvidia-smi 470.256.02` 2×K80
- [x] ✅ Host nvidia-uvm persistence dynamic major (511/507) via `nvidia-uvm-devices.service` Before `pve-guests`
- [x] ✅ LXC 131 `hlh-ai-engine-egpu-k80` 192.168.1.31 privileged `nesting=1,keyctl=1,fuse=1` + `/dev/nvidia*` cgroup 195:/51x + bind mounts for both GK210 chips
- [x] ✅ Model storage same path host and CT: `/srv/ai/models` bind mount `mp0` (RaidZ1-6TB ZFS 775)
- [x] ✅ CUDA toolkit 11.8 on noble 24.04 via ubuntu2204 repo + jammy libtinfo5 pin 100 + libnvidia-compute-470 470 reuse (hold 470/535/cuda)
- [x] ✅ llama.cpp `GGML_CUDA=ON` `ARCH=37` `FA=OFF` built with gcc-11, `nvidia-smi -L` 2 GPUs, `ai-engine` on :80 `Mellum2-12B...` 32K q4_0 `-ngl 99` `CUDA_VISIBLE_DEVICES=0,1`
- [x] ✅ `k80-switch-model.sh` v1.7.0-k80 (`/usr/local/bin` + `/srv/ai/models/k80-switch-model.sh`) banner 24GB
- [ ] Deploy nuke/rebuild 131 with new bootstrap + dynamic UVM + fuse (this commit)
- [ ] Verify `nvidia-uvm` major on host 7.0.14-11-pve after reboot (expect 511), check `pct exec 131 -- ls -l /dev/nvidia*` and `nvidia-smi -L`
- [ ] Compare K80 `llama-bench` without MTP vs with ngram (MTP draft `CUBLAS_STATUS_ARCH_MISMATCH` on cc 3.7)

## This Week

- [ ] Run full `deploy-hlh-ai-engine-egpu-k80.sh` cycle (destroy→recreate→bootstrap) with `--skip-host-driver` after first host pin
- [ ] Test `k80-switch-model.sh` model switching after LXC bootstrap (Mellum 12B → Qwen35B, verify spillover)
- [ ] Validate MI60 reuse via `/srv/ai/models/k80-switch-model.sh` (gfx900) — no Vulkan/RAD V, still CUDA
- [ ] Verify GPU pinning persists across container rebuilds and `tof`u `mp0` bind mount
