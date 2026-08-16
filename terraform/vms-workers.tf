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
  # 100GB, raised from 60GB on 2026-08-16. containerd's image cache alone was
  # 32GB, which pushed worker-2's root filesystem to 75% and tripped Ceph's
  # MON_DISK_LOW -- the mons keep their database at dataDirHostPath
  # /var/lib/rook on the NODE root disk, not in the Ceph pool, so a tight node
  # root disk degrades cluster health. Growing an existing VM only enlarges the
  # virtual device; ansible/roles/common grows the partition and filesystem.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.node_root_disk_size
    ssd          = true
  }

  # NO scsi1/scsi2 OSD disks any more. Ceph OSDs are now backed by a
  # PCIe-passthrough Samsung 990 PRO 4TB per worker (0000:41/42/43:00 ->
  # 9111/9112/9113), attached outside Terraform via `qm set -hostpci0`.
  #
  # The old scsi1 (100GB) + scsi2 (200GB) virtual disks were all carved out of
  # the single Solidigm P41 Plus that also holds every VM root disk, so all six
  # OSDs plus every VM shared one DRAM-less consumer NVMe. That produced
  # persistent "OSD(s) experiencing slow operations in BlueStore" warnings.
  # Drained, purged and deleted 2026-08-16, reclaiming ~354GB.
  #
  # Do NOT re-add them: rook-ceph's deviceFilter is "^nvme0n1$", but a disk
  # appearing at sdb/sdc is exactly the kind of thing a future filter change
  # would silently adopt, rebuilding the problem.

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
