# =============================================================================
# devbox -- remote T3 Code / Claude Code workstation LXC (2026-09-26)
# =============================================================================
# Not part of the k8s cluster -- lives here only because this is the module
# that already holds the Proxmox provider, token and state (same as
# lxc-ryan-minecraft.tf). Supersedes the VLAN 30 "agent sandbox" design in
# docs/agent-sandbox.md: this box is on the PRIMARY LAN on purpose, so it can
# do infra work (Proxmox API, UniFi, kubectl) the same as the desktop. The
# trade-off is that a runaway agent here can reach everything the desktop can.
#
# The DHCP reservation for the MAC below and the devbox.home DNS record live in
# UnifiTerraform/dhcp_reservations.tf / pihole_dns.tf. The primary pool is
# .6-.254, so the reservation is what keeps .230 from being handed out.
#
# Sizing: an LXC's cores and memory are caps, not reservations -- an idle box
# costs ~1-2 GiB. 128 cores is a full socket's worth of threads; a big parallel
# build can contend with k8s-homelab-0 (9121) and CT 200 while it runs.
#
# Apply with -target: the VM resources in this state have drifted (the cluster
# was collapsed to 9121 outside Terraform), and a plain apply would restart
# and regrow the stopped 9101-9113.

variable "devbox" {
  description = "Remote T3 Code / Claude Code dev box"
  type = object({
    vm_id  = number
    ip     = string
    mac    = string
    cores  = number
    memory = number # MiB
    disk   = number # GiB
  })
  default = {
    vm_id  = 201
    ip     = "10.1.0.230"
    mac    = "BC:24:11:10:02:30"
    cores  = 128
    memory = 49152
    disk   = 300
  }
}

resource "proxmox_virtual_environment_container" "devbox" {
  node_name     = var.proxmox_node
  vm_id         = var.devbox.vm_id
  description   = "Remote T3 Code / Claude Code dev box (primary LAN). Managed by Terraform."
  tags          = ["dev", "t3"]
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = var.devbox.cores
  }

  memory {
    dedicated = var.devbox.memory
    swap      = 4096
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.devbox.disk
  }

  # nesting lets systemd, docker and bwrap/user namespaces work inside an
  # unprivileged CT (verified in CT 200, see docs/agent-sandbox.md).
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
    mac_address = var.devbox.mac
  }

  initialization {
    hostname = "devbox"

    dns {
      servers = ["10.1.0.142"]
    }

    ip_config {
      ipv4 {
        address = "${var.devbox.ip}/24"
        gateway = "10.1.0.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}

output "devbox_ip" {
  value = var.devbox.ip
}
