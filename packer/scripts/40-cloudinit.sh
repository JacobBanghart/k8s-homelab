#!/bin/bash
set -euxo pipefail

# Generalize the image before it's converted to a Proxmox template: clear
# machine identity and cloud-init state so each Terraform clone gets fresh
# ones on first boot.

cloud-init clean --logs --seed || true
rm -f /etc/machine-id /var/lib/dbus/machine-id
touch /etc/machine-id

truncate -s 0 /etc/hostname
rm -f /etc/ssh/ssh_host_*

apt-get clean
rm -rf /var/lib/apt/lists/*
history -c || true
