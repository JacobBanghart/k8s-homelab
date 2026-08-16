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
    cores  = optional(number, 6)
    memory = optional(number, 6144)
    # Ballooning floor -- now set EQUAL to `memory`, which disables ballooning.
    #
    # The old comment here had the hazard right but the mitigation wrong. It
    # said to keep the floor "comfortably above the node's real working set",
    # because kubelet computes allocatable from MemTotal at startup and never
    # learns about balloon inflation. The flaw is that kubelet does not
    # schedule against the working set, it schedules against REQUESTS -- and
    # requests are allowed to exceed observed usage by a wide margin.
    #
    # That is not theoretical. On 2026-08-16 the workers were found ballooned
    # down to their 16384 floor (guest MemTotal 15.0GiB) while kubelet still
    # advertised the boot-time ~22.9GiB, and worker-1 was carrying 19.4GiB of
    # requests. The node had accepted 19GiB of promises on a 15GiB machine.
    # It only became visible when the kubelet restarted during the Kubernetes
    # 1.31 upgrade and re-read MemTotal: allocatable dropped to 15.2GiB, two
    # workers jumped to 99% requested, and pods began failing to schedule with
    # "Insufficient memory". It is also the most likely explanation for the
    # 2026-08-09 OOM that killed the homestead JVM and took k8s-worker-2
    # NotReady.
    #
    # There is no safe floor below `memory` for a Kubernetes node. Any gap is
    # memory kubelet believes it has and does not. Ballooning is a fine tool
    # for guests that tolerate a moving MemTotal; kubelet is not one of them.
    memory_min = optional(number, 6144)
    # Per-node golden-image override; null means use var.template_vm_id.
    # Set this on ONE node to rebuild it onto a new image, then clear it once
    # the fleet has caught up. Never bump var.template_vm_id itself -- it is
    # shared, and clone.vm_id is ForceNew, so it replaces all six nodes.
    template_vm_id = optional(number, null)
  }))
  default = {
    k8s-master-0 = { ip = "10.4.0.10", vm_id = 9101, template_vm_id = 9001 }
    k8s-master-1 = { ip = "10.4.0.11", vm_id = 9102, template_vm_id = 9001 }
    k8s-master-2 = { ip = "10.4.0.12", vm_id = 9103, template_vm_id = 9001 }
  }
}

variable "workers" {
  description = "Worker node definitions: hostname => static IP (no CIDR)"
  type = map(object({
    ip     = string
    vm_id  = number
    cores = optional(number, 20)
    # 24GiB, up from 15GiB (2026-08-15). 15GiB was set on 2026-08-09 against
    # 25.8GiB of cluster-wide pod requests, which left room to evacuate a node.
    # Requests have since grown to 30.2GiB (11796/7418/11744 Mi per worker),
    # putting two workers at 99% of allocatable. Sizing here is driven by the
    # drain constraint, not by steady-state usage: evacuating one worker must
    # fit on the other two. At 24GiB the guest yields ~19.1GiB allocatable, so
    # two nodes hold 38.2GiB against 30.2GiB of requests. At 15GiB they held
    # 23.8GiB and a drain could not fit at all -- the cluster could not roll.
    #
    # Do NOT read this as a return to the pre-2026-08-09 27GiB. That number was
    # derived from a `kubectl top` reading inflated by accumulated guest page
    # cache; this one is derived from scheduler requests. Re-check it the same
    # way (`kubectl describe nodes | grep -A5 "Allocated resources"`) before
    # changing it, and remember allocatable is only ~77% of guest RAM.
    memory = optional(number, 24576)
    # Set EQUAL to `memory` -- see the long note on masters.memory_min for why
    # any gap is unsafe on a Kubernetes node.
    #
    # This is the value that actually bit. It was raised 12288 -> 16384 on the
    # reasoning that the floor sat "above observed steady-state usage
    # (7.5-9.8GiB) with margin" -- true of usage, irrelevant to scheduling.
    # Requests on worker-1 had reached 19.4GiB, so once the balloon inflated to
    # the 16384 floor the node was ~4GiB short of the promises it had already
    # made, with kubelet unaware.
    #
    # If RAM genuinely has to be returned to the host, lower `memory` and
    # reboot the guest. Do not reintroduce a floor below it.
    memory_min = optional(number, 24576)
    # Per-node golden-image override; null means use var.template_vm_id.
    # Set this on ONE node to rebuild it onto a new image, then clear it once
    # the fleet has caught up. Never bump var.template_vm_id itself -- it is
    # shared, and clone.vm_id is ForceNew, so it replaces all six nodes.
    template_vm_id = optional(number, null)
  }))
  default = {
    k8s-worker-0 = { ip = "10.4.0.20", vm_id = 9111, template_vm_id = 9001 }
    k8s-worker-1 = { ip = "10.4.0.21", vm_id = 9112, template_vm_id = 9001 }
    k8s-worker-2 = { ip = "10.4.0.22", vm_id = 9113, template_vm_id = 9001 }
  }
}

variable "node_root_disk_size" {
  description = <<-EOT
    Size in GB of each worker's root disk. Must leave room for containerd's
    image cache (~32GB observed) on top of the OS: the Ceph mons store their
    database on the node root filesystem via dataDirHostPath, so filling it
    trips MON_DISK_LOW and degrades cluster health.
  EOT
  type        = number
  default     = 100
}

# ceph_osd_disk_size / ceph_osd_disk_size_2 were removed 2026-08-16 along with
# the scsi1/scsi2 disk blocks in vms-workers.tf. Ceph OSDs are now backed by a
# PCIe-passthrough Samsung 990 PRO 4TB per worker rather than virtual disks
# carved out of the hypervisor's single Solidigm NVMe. See vms-workers.tf.
