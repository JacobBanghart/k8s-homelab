resource "proxmox_virtual_environment_vm" "worker" {
  for_each = var.workers

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  clone {
    # See the note in vms-masters.tf: per-node override, because bumping
    # var.template_vm_id replaces every node at once. A worker rebuild also
    # destroys its Ceph OSD disk, so its OSDs must be out and purged, and the
    # cluster back to HEALTH_OK, before the replace runs.
    vm_id = coalesce(each.value.template_vm_id, var.template_vm_id)
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = each.value.memory_min
  }

  agent {
    enabled = true
  }

  # ssd = true on every disk: var.storage_pool is the `nvme` datastore, so all
  # of these are NVMe-backed. Without this the guest sees
  # /sys/block/sdX/queue/rotational = 1 and every layer above tunes for spinning
  # rust -- Ceph in particular picked its `hdd` BlueStore cache sizes and shard
  # counts, and classed all six OSDs as `hdd` in CRUSH. Set 2026-08-09.
  # Takes effect on VM restart; the flag is a device property, not live-settable.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = 60
    ssd          = true
  }

  # Dedicated raw block device for Rook/Ceph OSD backing — left unformatted,
  # Ceph consumes the whole device directly.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi1"
    size         = var.ceph_osd_disk_size
    ssd          = true
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
    ssd          = true
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
