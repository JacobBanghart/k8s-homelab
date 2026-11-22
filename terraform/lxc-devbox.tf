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

variable "devbox" {
  description = "Remote T3 Code / Claude Code dev box"
  type = object({
    vm_id  = number
    ip     = string
    mac    = string
    cores  = number
    memory = number # MiB
    disk   = number # GiB
    # Rootfs moved from the `nvme` dir pool (raw image on a loop device) to the
    # `fast` ZFS mirror with `pct move-volume` on 2026-11-03, because parallel
    # Rust worktrees (~10 GiB of target/ each) filled 300G and the T3 server's
    # SQLite then failed every run. On ZFS it's a subvol, so `disk` is just a
    # quota: raise it here and apply (in place, no restart).
    datastore = string
  })
  default = {
    vm_id     = 201
    ip        = "10.1.0.230"
    mac       = "BC:24:11:10:02:30"
    cores     = 128
    memory    = 49152
    disk      = 1000
    datastore = "fast"
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
  protection    = true

  cpu {
    cores = var.devbox.cores
  }

  memory {
    dedicated = var.devbox.memory
    swap      = 4096
  }

  disk {
    datastore_id = var.devbox.datastore
    size         = var.devbox.disk
  }

  # nesting lets systemd, docker and bwrap/user namespaces work inside an
  # unprivileged CT (verified in CT 200, see docs/agent-sandbox.md).
  features {
    nesting = true
  }

  # /dev/kvm for the Android emulator (nijii-app's Maestro and screenshot tests).
  # gid 992 is the container's kvm group; jqwop joins it inside the CT.
  # Proxmox only lets root@pam set device passthrough, and the provider uses an API
  # token, so this was applied with `pct set 201 -dev0 /dev/kvm,gid=992,mode=0660`.
  # Declaring it here keeps the plan clean; changing it needs the same root step.
  device_passthrough {
    path = "/dev/kvm"
    gid  = 992
    mode = "0660"
  }

  # GT 1030 render node (host driver: nouveau), for GPU tests in Docker such as
  # Quickshell VRAM measurement. gid 991 is the container's render group.
  # Applied as root with `pct set 201 -dev1 /dev/dri/renderD128,gid=991,mode=0660`
  # (hot-plugged, no restart), like dev0 above.
  device_passthrough {
    path = "/dev/dri/renderD128"
    gid  = 991
    mode = "0660"
  }

  # TUN for tailscaled (kernel networking, joined to Headscale as `devbox`).
  # Applied live with `pct set 201 -dev2 /dev/net/tun,mode=0666`.
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
