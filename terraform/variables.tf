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
  description = "Default Proxmox node name to provision VMs on. Used as the fallback for any entry in `masters`/`workers` that doesn't set its own `node` -- kept so a single-host deployment (the common case, and this project's current real setup) needs zero config changes."
  type        = string
  default     = "prox"
}

variable "template_vm_id" {
  description = "VMID of the Packer-built golden image template to clone. See docs/architecture.md ('Multi-host provisioning') for what this means once more than one physical Proxmox host is involved -- the template must exist under this VMID on every host a VM might be cloned onto, either via shared storage or a separate per-host Packer build."
  type        = number
  default     = 9000
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disks. Must be visible on every physical host referenced by `masters`/`workers`/`proxmox_node` -- a purely local (non-shared) pool of this name existing on multiple hosts is fine for VM disks (each host has its own local copy), but the *template* being cloned needs extra care, see docs/architecture.md."
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
  description = "Master node definitions: hostname => static IP, VMID, sizing, and which physical Proxmox host to clone onto. `node` defaults to `var.proxmox_node` (today's single real host) so existing single-host deployments don't need to set anything. For genuine multi-host HA, give each master a different `node` -- see the `master_node_anti_affinity` check block below."
  type = map(object({
    ip     = string
    vm_id  = number
    cores  = optional(number, 2)
    memory = optional(number, 4096)
    node   = optional(string, "prox")
  }))
  default = {
    k8s-master-0 = { ip = "10.4.0.10", vm_id = 9101 }
    k8s-master-1 = { ip = "10.4.0.11", vm_id = 9102 }
    k8s-master-2 = { ip = "10.4.0.12", vm_id = 9103 }
  }
}

variable "workers" {
  description = "Worker node definitions: hostname => static IP, VMID, sizing, and which physical Proxmox host to clone onto. `node` defaults to `var.proxmox_node` (today's single real host) so existing single-host deployments don't need to set anything. Workers have no quorum requirement, so spreading them across hosts is a capacity/blast-radius choice, not a correctness one."
  type = map(object({
    ip     = string
    vm_id  = number
    cores  = optional(number, 6)
    memory = optional(number, 12288)
    node   = optional(string, "prox")
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

# Real HA only exists if the 3 masters survive the loss of one physical
# Proxmox host, which requires them on 3 *different* hosts. This is
# deliberately a `check` block (warns, never blocks `plan`/`apply`) rather
# than a hard `precondition` failure: the project's own real deployment is
# still single-host today (all three masters share `proxmox_node`'s
# default), and a hard failure here would break that working, intentional
# setup. See docs/architecture.md ("Multi-host provisioning") for the
# reasoning.
check "master_node_anti_affinity" {
  assert {
    condition     = length(distinct([for m in var.masters : m.node])) == length(var.masters)
    error_message = "Two or more masters in var.masters share the same Proxmox `node` -- on a single-host deployment this is expected and fine, but if you believe you're running multi-host, this means losing that one physical host takes down more than one master, defeating the point of 3-master etcd quorum. See docs/architecture.md."
  }
}
