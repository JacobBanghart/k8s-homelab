#!/bin/bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get install -y \
  ca-certificates curl gnupg lsb-release apt-transport-https \
  qemu-guest-agent cloud-init open-iscsi nfs-common

systemctl enable qemu-guest-agent
systemctl enable cloud-init

# Swap must be permanently off for kubelet
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab
