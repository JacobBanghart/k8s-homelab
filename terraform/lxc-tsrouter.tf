# =============================================================================
# tsrouter -- Headscale subnet router + exit node LXC (2026-11-14)
# =============================================================================
# Not part of the k8s cluster; lives here for the same reason as lxc-devbox.tf.
# Advertises 10.1.0.0/24 (primary LAN) and 10.4.0.0/24 (k8s-lab) to the tailnet
# at headscale.jacobbanghart.com and offers itself as an exit node. Tailnet
# traffic leaves it SNATed to .231, so UniFi zones and Pi-hole see an ordinary
# primary-LAN client.
#
# Why its own CT: the rescue path into the homelab must not depend on k8s
# (Headscale itself runs there) or on the devbox, which gets loaded and
# rebooted. IP forwarding is enabled inside this CT's network namespace only;
# prox.mox itself keeps ip_forward=0.
#
# The DHCP reservation for the MAC below lives in
# UnifiTerraform/dhcp_reservations.tf.

variable "tsrouter" {
  description = "Headscale subnet router / exit node"
  type = object({
    vm_id  = number
    ip     = string
    mac    = string
    cores  = number
    memory = number # MiB
    disk   = number # GiB
  })
  default = {
    vm_id  = 202
    ip     = "10.1.0.231"
    mac    = "BC:24:11:10:02:31"
    cores  = 2
    memory = 512
    disk   = 4
  }
}

resource "proxmox_virtual_environment_container" "tsrouter" {
  node_name     = var.proxmox_node
  vm_id         = var.tsrouter.vm_id
  description   = "Headscale subnet router + exit node (primary LAN). Managed by Terraform."
  tags          = ["network", "tailscale"]
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = var.tsrouter.cores
  }

  memory {
    dedicated = var.tsrouter.memory
    swap      = 512
  }

  disk {
    datastore_id = "fast"
    size         = var.tsrouter.disk
  }

  features {
    nesting = true
  }

  # TUN for tailscaled (kernel networking). Device passthrough needs root@pam,
  # so it was applied with `pct set 202 -dev0 /dev/net/tun,mode=0666` after
  # create, like the devbox's devices.
  device_passthrough {
    path = "/dev/net/tun"
    mode = "0666"
  }

  operating_system {
    template_file_id = "${var.storage_pool}:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
    type             = "ubuntu"
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = var.tsrouter.mac
  }

  initialization {
    hostname = "tsrouter"

    dns {
      servers = ["10.1.0.142"]
    }

    ip_config {
      ipv4 {
        address = "${var.tsrouter.ip}/24"
        gateway = "10.1.0.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}

output "tsrouter_ip" {
  value = var.tsrouter.ip
}
