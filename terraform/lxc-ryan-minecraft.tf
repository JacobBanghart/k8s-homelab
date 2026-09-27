# =============================================================================
# Ryan's Minecraft test LXC (2026-09-07)
# =============================================================================
# Not part of the k8s cluster -- lives here only because this is the module
# that already holds the Proxmox provider, token and state. It sits on the
# friend VLAN (20, "Ryan Vlan", managed in UnifiTerraform/vlans.tf), NOT on
# k8s-lab, so it has no reach into the cluster or the primary LAN.
#
# The WAN port forwards (SSH + 50000 tcp/udp) and the DHCP reservation for the
# MAC below live in UnifiTerraform/port_forwards.tf / dhcp_reservations.tf.
# The MAC is pinned here so that reservation can be declared before the
# container exists; keep the two in sync.
#
# Host RAM note: the host was already at ~80% (see masters.memory_min in
# variables.tf), which is Proxmox's auto-balloon trigger. An LXC is a cgroup
# limit, not a reservation, so only what the JVM actually touches counts --
# but a -Xmx12G server will still land ~13GB on the host. Watch `free` on prox.

variable "ryan_minecraft" {
  description = "Ryan's Minecraft test container"
  type = object({
    vm_id  = number
    ip     = string
    mac    = string
    cores  = number
    memory = number # MiB
    disk   = number # GiB
  })
  default = {
    vm_id  = 200
    ip     = "10.2.0.50"
    mac    = "BC:24:11:20:00:50"
    cores  = 24
    memory = 49152
    disk   = 240
  }
}

resource "proxmox_virtual_environment_container" "ryan_minecraft" {
  node_name     = var.proxmox_node
  vm_id         = var.ryan_minecraft.vm_id
  description   = "Ryan's Minecraft test box (friend VLAN 20). Managed by Terraform."
  tags          = ["friend", "minecraft"]
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = var.ryan_minecraft.cores
  }

  memory {
    dedicated = var.ryan_minecraft.memory
    swap      = 0
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.ryan_minecraft.disk
  }

  # nesting lets systemd and docker work inside an unprivileged CT.
  features {
    nesting = true
  }

  operating_system {
    template_file_id = "${var.storage_pool}:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
    type             = "ubuntu"
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    vlan_id     = 20
    mac_address = var.ryan_minecraft.mac
  }

  initialization {
    hostname = "ryan-minecraft"

    ip_config {
      ipv4 {
        address = "${var.ryan_minecraft.ip}/24"
        gateway = "10.2.0.1"
      }
    }

    # Root gets Jacob's key so the box can be reached to add Ryan's key
    # (or drop his key into this list -- adding a key here recreates the CT,
    # so do it inside the container once it holds a world).
    user_account {
      keys = [var.ssh_public_key]
    }
  }
}

output "ryan_minecraft_ip" {
  value = var.ryan_minecraft.ip
}
