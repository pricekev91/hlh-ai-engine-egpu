variable "pm_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API token ID"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node name"
  type        = string
  default     = "prox01"
}

variable "hostname" {
  description = "LXC hostname"
  type        = string
  default     = "hlh-ai-engine-v100"
}

variable "vmid" {
  description = "LXC VMID"
  type        = number
  default     = 131
}

variable "ostemplate" {
  description = "Proxmox LXC template"
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "storage" {
  description = "Proxmox storage for rootfs"
  type        = string
  default     = "RaidZ1-6TB"
}

variable "rootfs_size_gb" {
  description = "Root filesystem size in GB"
  type        = number
  default     = 64
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 12
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 8192
}

variable "swap" {
  description = "Swap in MB"
  type        = number
  default     = 1024
}

variable "bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "ip_cidr" {
  description = "Static IP in CIDR format"
  type        = string
  default     = "192.168.1.31/24"
}

variable "gateway" {
  description = "Gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "network_tag" {
  description = "VLAN tag (0 means untagged)"
  type        = number
  default     = 0
}

variable "lxc_root_password" {
  description = "Optional root password for LXC"
  type        = string
  default     = ""
  sensitive   = true
}

variable "egpu_pci_address" {
  description = "PCI address of the eGPU on the OCuLink connector. For V100 this is single GV100 at 0000:c5:00.0 (10de:1df0) via GPP 00:03.1."
  type        = string
  default     = "0000:c5:00.0"
}

variable "nvidia_driver_version" {
  description = "Pinned NVIDIA driver version for Tesla V100 (Volta cc 7.0). 550.163.01 is stable in Debian trixie; R580 (580.65.06) is last branch supporting Volta (CUDA 12.8/12.9 last fully)."
  type        = string
  default     = "550.163.01-2"
}

variable "cuda_version" {
  description = "Pinned CUDA toolkit version for V100 (12.4 with 550 driver; 12.8 last with 570/580)."
  type        = string
  default     = "12.4.1"
}

variable "description" {
  description = "LXC description"
  type        = string
  default     = "llama.cpp AI engine with CUDA 12.4 + driver 550.163.01 for Tesla V100 (GV100 32GB cc 7.0) via OCuLink c5:00.0, model storage on RaidZ1-6TB — sm70 FA ON"
}

variable "model_mount_path" {
  description = "Host path for model storage mount point inside LXC"
  type        = string
  default     = "/srv/ai/models"
}

variable "model_storage" {
  description = "Proxmox storage pool for model volume"
  type        = string
  default     = "RaidZ1-6TB"
}
