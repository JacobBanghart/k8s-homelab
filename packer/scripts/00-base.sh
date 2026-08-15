#!/bin/bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get install -y \
  ca-certificates curl gnupg lsb-release apt-transport-https \
  qemu-guest-agent cloud-init open-iscsi nfs-common

systemctl enable qemu-guest-agent

# cloud-init.target, not cloud-init.service. Upstream renamed cloud-init.service
# to cloud-init-network.service in 24.3 and Ubuntu 26.04 no longer ships the old
# alias, so `systemctl enable cloud-init` fails outright there. The target is the
# supported handle for the whole stack and is present on 22.04 as well, so this
# stays correct across releases.
systemctl enable cloud-init.target

# Swap must be permanently off for kubelet
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

# Name the NIC eth0 at the kernel level instead of the predictable ens18.
#
# Proxmox's cloud-init network config renames the interface to eth0 via a
# netplan `set-name`. On 22.04 that rename succeeds, which is why every
# existing node is eth0. On 26.04 systemd refuses to rename an interface that
# is already up -- cloud-init logs "[busy] Error renaming ... from ens18 to
# eth0", gives up, and finishes `degraded` with the NIC still called ens18.
#
# That is not cosmetic: ansible/inventory/group_vars/all.yml pins
# control_plane_vip_interface: "eth0" for keepalived, and docs/decisions.md
# records keepalived refusing to start when that name was wrong. Setting the
# name in the kernel removes the rename step entirely and keeps new nodes
# identical to the existing fleet.
#
# A grub.d drop-in rather than editing GRUB_CMDLINE_LINUX in place: it is
# idempotent across rebuilds and cannot mangle an existing value.
install -d /etc/default/grub.d
cat > /etc/default/grub.d/99-net-ifnames.cfg <<'EOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX net.ifnames=0 biosdevname=0"
EOF
update-grub
grep -q 'net.ifnames=0' /boot/grub/grub.cfg \
  || { echo "net.ifnames=0 did not reach grub.cfg" >&2; exit 1; }
