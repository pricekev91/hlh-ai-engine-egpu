# TODO

Active items in progress. These are the current focus areas.

## Active

- [x] ✅ GPU passthrough working: cgroup device-allow + `/dev/dri` bind-mount (card-agnostic)
- [x] ✅ Vulkan backend confirmed: ~54 tok/s on eGPU (RX480/0000:c5:00.0) via RADV
- [x] ✅ Mellum2-12B-A2.5B-Thinking-Q3_K_M.gguf as default model
- [x] ✅ Service running: `ai-engine` on port 80 (llama.cpp web UI)
- [ ] Deploy fix for leading spaces in cgroup/mount lines → prevents Proxmox 9.x parse errors
- [ ] Compare eGPU RX480 vs iGPU 890M inference performance (Vulkan)

## This Week

- [ ] Run full deploy-hlh-ai-engine-egpu-vulkan.sh cycle (destroy→recreate→bootstrap)
- [ ] Test model switching after LXC bootstrap (vulkan-switch-model.sh)
- [ ] Validate spillover behavior with larger models (30B Q4_K_M → expects RAM spill)
- [ ] Verify GPU pinning persists across container rebuilds
