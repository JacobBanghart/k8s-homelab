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

  # Second OSD disk added ahead of the dev-cluster migration -- original
  # 100GB/worker (300GB raw, ~81GiB usable after 3x replication) was too
  # tight against dev's real data footprint (~75-90GB). Additive rather
  # than resizing the existing scsi1 disks live, to avoid any risk to
  # already-written OSD data.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi2"
    size         = var.ceph_osd_disk_size_2
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
