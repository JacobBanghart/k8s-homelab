variable "proxmox_api_url" {
  description = "Proxmox API endpoint, e.g. https://10.1.0.99:8006/"
  type        = string
  default     = "https://10.1.0.99:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token in 'user@realm!tokenid=secret' format"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification (self-signed Proxmox cert)"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name to provision VMs on"
  type        = string
  default     = "prox"
}

variable "template_vm_id" {
  description = "VMID of the Packer-built golden image template to clone"
  type        = number
  default     = 9000
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disks"
  type        = string
  default     = "nvme"
}

variable "vlan_tag" {
  description = "VLAN tag for the k8s-lab network (see UnifiTerraform/vlans.tf)"
  type        = number
  default     = 30
}

variable "network_gateway" {
  description = "Gateway IP for the k8s-lab VLAN"
  type        = string
  default     = "10.4.0.1"
}

variable "network_prefix" {
  description = "CIDR prefix length for the k8s-lab VLAN"
  type        = number
  default     = 24
}

variable "ssh_public_key" {
  description = "SSH public key injected into all cluster nodes via cloud-init"
  type        = string
}

variable "masters" {
  description = "Master node definitions: hostname => static IP (no CIDR)"
  type = map(object({
    ip     = string
    vm_id  = number
    cores  = optional(number, 2)
    memory = optional(number, 4096)
  }))
  default = {
    k8s-master-0 = { ip = "10.4.0.10", vm_id = 9101 }
    k8s-master-1 = { ip = "10.4.0.11", vm_id = 9102 }
    k8s-master-2 = { ip = "10.4.0.12", vm_id = 9103 }
  }
}

variable "workers" {
  description = "Worker node definitions: hostname => static IP (no CIDR)"
  type = map(object({
    ip     = string
    vm_id  = number
    cores  = optional(number, 6)
    memory = optional(number, 12288)
  }))
  default = {
    k8s-worker-0 = { ip = "10.4.0.20", vm_id = 9111 }
    k8s-worker-1 = { ip = "10.4.0.21", vm_id = 9112 }
    k8s-worker-2 = { ip = "10.4.0.22", vm_id = 9113 }
  }
}

variable "ceph_osd_disk_size" {
  description = "Size in GB of the dedicated raw block device added to each worker for Rook/Ceph OSDs"
  type        = number
  default     = 100
}
