resource "proxmox_virtual_environment_vm" "worker" {
  for_each = var.workers

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  agent {
    enabled = true
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = 60
  }

  # Dedicated raw block device for Rook/Ceph OSD backing — left unformatted,
  # Ceph consumes the whole device directly.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi1"
    size         = var.ceph_osd_disk_size
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_tag
  }

  initialization {
    datastore_id = var.storage_pool

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_prefix}"
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
