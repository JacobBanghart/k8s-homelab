#!/bin/bash
# Nightly backup of the Proxmox host's own config (not guest data) to TrueNAS.
#
# Why: /etc/pve, the network config and the hookscripts exist only on the
# boot SSD (a ~2016 Crucial MX200, 52k+ hours). Guests rebuild from
# Packer/Terraform/Ansible, but the host itself did not -- a dead boot disk
# meant reconfiguring prox by hand from memory.
#
# Where it goes: a dated tarball in TrueNAS /mnt/HDDPool/Backup/prox-config/,
# which TrueNAS's own 02:00 restic job ships offsite to S3. The SSH key used
# here is authorized on TrueNAS root with a forced command that can ONLY write
# that tarball and prune ones older than 30 days (see README.md).
#
# Installed at /usr/local/sbin/prox-config-backup.sh, run by
# prox-config-backup.timer (01:30, before the 02:00 offsite run).
set -euo pipefail

TRUENAS=root@10.1.0.45
KEY=/root/.ssh/id_ed25519_prox_backup

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A human-readable manifest, so a rebuild on a fresh boot disk has a checklist
# (package set, disks, NICs, versions) and not just raw config files.
m="$work/manifest"
mkdir -p "$m"
pveversion -v            > "$m/pveversion.txt"      2>&1 || true
dpkg --get-selections    > "$m/dpkg-selections.txt" 2>&1 || true
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS > "$m/lsblk.txt" 2>&1 || true
lspci -nn                > "$m/lspci.txt"           2>&1 || true
ip -d addr               > "$m/ip-addr.txt"         2>&1 || true
cat /proc/cmdline        > "$m/cmdline.txt"         2>&1 || true
qm list                  > "$m/qm-list.txt"         2>&1 || true
pct list                 > "$m/pct-list.txt"        2>&1 || true
pvesm status             > "$m/pvesm-status.txt"    2>&1 || true

paths=(
  /etc/pve                       # every VM/CT config, storage.cfg, users/tokens, firewall
  /etc/network/interfaces        # bond0 / vmbr0 / VLAN setup
  /etc/network/interfaces.d
  /etc/hosts /etc/hostname /etc/resolv.conf /etc/timezone
  /etc/default/grub /etc/kernel  # IOMMU / passthrough kernel args
  /etc/modprobe.d /etc/modules /etc/modules-load.d
  /etc/sysctl.d /etc/udev/rules.d
  /etc/vzdump.conf /etc/cron.d /var/spool/cron/crontabs
  /etc/systemd/system            # custom units, incl. this backup's timer
  /etc/apt/sources.list /etc/apt/sources.list.d
  /usr/local/bin /usr/local/sbin # pve-fix-fw-bridges.sh, this script
  /var/lib/vz/snippets           # fix-fw-bridge.pl hookscript
  /root/.ssh
)
existing=()
for p in "${paths[@]}"; do [ -e "$p" ] && existing+=("$p"); done
# Storage-level snippets dirs (e.g. /mnt/pve/nvme/snippets), if any exist.
for p in /mnt/pve/*/snippets; do [ -d "$p" ] && existing+=("$p"); done

# mst*: the Mellanox firmware tools (mstflint etc., ~70 MB of binaries for
# the ConnectX-3) live in /usr/local/bin; reinstallable, not config.
tar -czf - --ignore-failed-read --exclude='usr/local/bin/mst*' \
    "${existing[@]}" -C "$work" manifest 2>/dev/null \
  | ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "$TRUENAS"

echo "prox-config-backup: sent ${#existing[@]} paths + manifest to $TRUENAS"
