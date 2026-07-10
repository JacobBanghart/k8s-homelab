packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

locals {
  # Derive the major release dir (e.g. "24.04") from the pinned point
  # release (e.g. "24.04.4") -- releases.ubuntu.com serves both under it.
  ubuntu_major        = join(".", slice(split(".", var.ubuntu_point_release), 0, 2))
  ubuntu_iso_url      = "https://releases.ubuntu.com/${local.ubuntu_major}/ubuntu-${var.ubuntu_point_release}-live-server-amd64.iso"
  ubuntu_iso_checksum = "file:https://releases.ubuntu.com/${local.ubuntu_major}/SHA256SUMS"
}

source "proxmox-iso" "k8s_golden" {
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = var.template_vm_id
  vm_name              = "k8s-golden"
  template_name        = "k8s-golden"
  template_description = "Ubuntu ${var.ubuntu_point_release} + containerd + kubeadm/kubelet/kubectl (pinned) — built by packer/k8s-node.pkr.hcl"

  boot_iso {
    type             = "scsi"
    iso_url          = local.ubuntu_iso_url
    iso_checksum     = local.ubuntu_iso_checksum
    unmount          = true
    iso_storage_pool = "local"
  }

  os = "l26"

  cpu_type = "host"
  cores    = 2
  sockets  = 1
  memory   = 4096

  scsi_controller = "virtio-scsi-single"

  disks {
    type         = "scsi"
    disk_size    = "20G"
    storage_pool = var.storage_pool
    format       = "qcow2"
    io_thread    = true
  }

  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  qemu_agent = true

  # Drop into the GRUB command-line shell ('c') and issue linux/initrd/boot
  # directly, rather than blindly editing the existing menu entry (whose
  # line layout in the edit box isn't reliably navigable by down-presses).
  boot_command = [
    "<wait5>c<wait>",
    "linux /casper/vmlinuz quiet autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  boot_wait = "10s"

  http_content = {
    "/meta-data" = ""
    "/user-data" = templatefile("${path.root}/http/user-data", {
      ssh_public_key = var.ssh_public_key
    })
  }

  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "30m"
}

build {
  sources = ["source.proxmox-iso.k8s_golden"]

  provisioner "shell" {
    execute_command = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/scripts/00-base.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/scripts/10-containerd.sh"
  }

  provisioner "shell" {
    execute_command  = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = ["K8S_VERSION=${var.kubernetes_version}"]
    script           = "${path.root}/scripts/20-k8s-binaries.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/scripts/30-sysctl-modules.sh"
  }

  provisioner "shell" {
    execute_command   = "sudo -E -S sh -c '{{ .Vars }} {{ .Path }}'"
    script            = "${path.root}/scripts/40-cloudinit.sh"
    expect_disconnect = true
  }
}
