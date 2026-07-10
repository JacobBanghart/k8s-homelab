variable "proxmox_api_url" {
  type    = string
  default = "https://10.1.0.99:8006/api2/json"
}

variable "proxmox_api_token_id" {
  type    = string
  default = "terraform@pve!k8s-homelab"
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type    = string
  default = "prox"
}

variable "storage_pool" {
  type    = string
  default = "nvme"
}

variable "template_vm_id" {
  type    = number
  default = 9000
}

variable "kubernetes_version" {
  description = "kubeadm/kubelet/kubectl minor version to pin, e.g. 1.30"
  type        = string
  default     = "1.30"
}

variable "ubuntu_point_release" {
  description = "Exact Ubuntu live-server point release to build from, e.g. 24.04.4. Must exist at https://releases.ubuntu.com/<major>/ -- bump this (not the scripts) to move to a newer point release or LTS."
  type        = string
  default     = "24.04.4"
}

variable "ssh_username" {
  type    = string
  default = "ansible"
}

variable "ssh_public_key" {
  type = string
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519_k8s_homelab"
}
