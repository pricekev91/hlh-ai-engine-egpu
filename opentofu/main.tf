terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = ">= 2.7.2"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
}

resource "proxmox_lxc" "hlh_ai_engine_egpu_k80" {
  target_node  = var.target_node
  hostname     = var.hostname
  ostemplate   = var.ostemplate
  vmid         = var.vmid
  cores        = var.cores
  memory       = var.memory
  swap         = var.swap
  unprivileged = false
  start        = true
  description  = var.description

  features {
    nesting = true
    keyctl  = true
    fuse    = true
  }

  network {
    name   = "eth0"
    bridge = var.bridge
    ip     = var.ip_cidr
    gw     = var.gateway
    tag    = var.network_tag
  }

  password = var.lxc_root_password != "" ? var.lxc_root_password : null

  rootfs {
    storage = var.storage
    size    = "${var.rootfs_size_gb}G"
  }

  # K80 Tesla GK210 dual-GPU via OCuLink (c7:00.0 + c8:00.0)
  # Both chips share the OCuLink switch at var.egpu_pci_address (0000:c5:00.0)
  # but are in separate IOMMU groups (23/24). LXC passthrough is via /dev/nvidia*
  # (cgroup + bind-mount), not hostpci. hostpci is not used for LXC; see deploy
  # script for c 195:* / c 511:* allows and /dev/nvidia* mounts.
  # We keep no hostpci device block here — the deploy script appends the
  # NVIDIA cgroup/mount entries post-create. This keeps the base resource
  # card-agnostic and pinned versions in variables.tf.

  # Model storage volume mount (host /srv/ai/models -> LXC /srv/ai/models)
  mp0 {
    path    = var.model_mount_path
    storage = var.model_storage
  }

  # NOTE: NVIDIA cgroup (c 195:* rwm, c 511:* rwm) and bind-mounts
  # (/dev/nvidia0, /dev/nvidia1, /dev/nvidiactl, /dev/nvidia-uvm*) are
  # appended by deploy-hlh-ai-engine-egpu-k80.sh. Manual equivalent:
  #   pct set <VMID> --lxc.conf 'lxc.cgroup2.devices.allow: c 195:* rwm'
  #   pct set <VMID> --lxc.conf 'lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file'
}

output "lxc_vmid" {
  value = proxmox_lxc.hlh_ai_engine_egpu_k80.vmid
}

output "lxc_hostname" {
  value = proxmox_lxc.hlh_ai_engine_egpu_k80.hostname
}
