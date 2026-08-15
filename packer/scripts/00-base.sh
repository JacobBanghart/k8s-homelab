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
