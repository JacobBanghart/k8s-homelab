# Single-node kubeadm VM (control plane + workloads). See var.single_node and
# docs/single-node-migration.md.
resource "proxmox_virtual_environment_vm" "single" {
  name      = var.single_node.name
  node_name = var.proxmox_node
  vm_id     = var.single_node.vm_id

  # One controller per disk so iothread actually applies.
  scsi_hardware = "virtio-scsi-single"

  clone {
    vm_id = var.single_node.template_vm_id
    full  = true
  }

  cpu {
    cores = var.single_node.cores
    type  = "host"
  }

  memory {
    dedicated = var.single_node.memory
    floating  = var.single_node.memory_min
  }

  agent {
    enabled = true
  }

  # Root: OS, containerd image cache, etcd, kubelet.
  disk {
    datastore_id = var.single_node.datastore_id
    interface    = "scsi0"
    size         = var.single_node.root_disk_size
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  # Data: every PersistentVolume (local-path-provisioner), mounted at
  # /var/lib/local-path by ansible/roles/single_node. Kept separate from root
  # so it can be snapshotted/replicated/moved on its own. discard is safe:
  # this is PCIe NVMe, not behind the SAS3216 HBA that faults on TRIM.
  disk {
    datastore_id = var.single_node.datastore_id
    interface    = "scsi1"
    size         = var.single_node.data_disk_size
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_tag
  }

  initialization {
    datastore_id = var.single_node.datastore_id

    ip_config {
      ipv4 {
        address = "${var.single_node.ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = "ansible"
      keys     = [var.ssh_public_key]
    }
  }

  operating_system {
    type = "l26"
  }
}
