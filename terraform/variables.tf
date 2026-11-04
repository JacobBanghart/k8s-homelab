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

variable "single_node" {
  description = <<-EOT
    The single-node kubeadm VM that replaces the 3+3 cluster
    (docs/single-node-migration.md). The old masters/workers (9101-9113) were
    destroyed in Phase 6 on 2026-11-03.

    No hostpci: passthrough makes QEMU pin every byte of guest RAM, which is
    what stranded ~50 GiB on the old workers. memory_min == memory keeps the
    balloon device (so free-page-reporting returns freed pages to the host)
    without ever inflating it under kubelet: kubelet computes allocatable
    from MemTotal at boot and never notices a balloon, so any floor below
    `memory` lets it schedule requests the guest can't hold (bit the old
    workers on 2026-08-16). `balloon: 0` does NOT disable this -- pvestatd
    reads it as "may shrink to zero". Only min == max does.
  EOT
  type = object({
    name           = string
    ip             = string
    vm_id          = number
    template_vm_id = number
    cores          = number
    memory         = number
    memory_min     = number
    root_disk_size = number
    data_disk_size = number
    datastore_id   = string
    # Separate because moving a cloud-init drive needs the VM powered off.
    cloudinit_datastore_id = string
  })
  default = {
    name           = "k8s-homelab-0"
    ip             = "10.4.0.30"
    vm_id          = 9121
    template_vm_id = 9001
    cores          = 32
    # 32 GiB during migration (host headroom); raised to 40 GiB at cutover
    # once the old VMs were shut down -- 32 left pod requests at 99%.
    memory         = 40960
    memory_min     = 40960
    root_disk_size = 100
    # local-path PV root.
    data_disk_size = 1000
    # ZFS mirror of two 990 Pros. Disks moved here from etcd-fast online with
    # `qm disk move` on 2026-11-03 (Phase 6).
    datastore_id = "fast"
    # Still on etcd-fast: set to "fast" at the next planned 9121 reboot (the
    # provider moves it then). Do this before etcd-fast is wiped.
    cloudinit_datastore_id = "etcd-fast"
  }
}
