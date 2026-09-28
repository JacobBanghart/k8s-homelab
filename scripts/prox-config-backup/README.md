# prox-config-backup

Nightly tarball of the Proxmox host's own configuration (not guest data) to
TrueNAS, which then ships it offsite with its existing 02:00 restic job.

| Piece | Location |
|---|---|
| Script | `/usr/local/sbin/prox-config-backup.sh` on prox |
| Timer | `prox-config-backup.timer`, 01:30 daily (`systemctl list-timers prox-config-backup.timer`) |
| SSH key | `/root/.ssh/id_ed25519_prox_backup` on prox (comment `prox-config-backup`) |
| Destination | TrueNAS `/mnt/HDDPool/Backup/prox-config/prox-config-YYYY-MM-DD.tar.gz`, 30 days kept |
| Offsite | `/mnt/HDDPool/Backup` is in TrueNAS `/root/restic-daily.sh` (02:00, tag `truenas-primary`) |

## The key is restricted

The key is authorized on TrueNAS root through the middleware (the
`sshpubkey` field of user root, which is how TrueNAS persists keys --
hand-editing `/root/.ssh/authorized_keys` does not survive). It carries a
forced command, so it can only write today's tarball and prune old ones:

```
command="/bin/sh -c 'd=/mnt/HDDPool/Backup/prox-config; mkdir -p $d; f=$d/prox-config-$(date +%Y-%m-%d).tar.gz; cat > $f.part && mv $f.part $f && find $d -name \"prox-config-*.tar.gz\" -mtime +30 -delete'",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 ... prox-config-backup
```

## Install / reinstall (from the desktop or devbox)

```sh
cd k8s-homelab/scripts/prox-config-backup
scp prox-config-backup.sh root@10.1.0.99:/usr/local/sbin/
scp prox-config-backup.{service,timer} root@10.1.0.99:/etc/systemd/system/
ssh root@10.1.0.99 'chmod 755 /usr/local/sbin/prox-config-backup.sh &&
  systemctl daemon-reload && systemctl enable --now prox-config-backup.timer'
```

On a rebuilt host the key is gone: generate a new one
(`ssh-keygen -t ed25519 -C prox-config-backup -f /root/.ssh/id_ed25519_prox_backup`)
and replace the old `prox-config-backup` line in TrueNAS root's `sshpubkey`.

## Restore

`tar -tzf prox-config-YYYY-MM-DD.tar.gz` to inspect; `manifest/` holds
`pveversion`, `dpkg-selections`, disks, NICs and the guest lists as a rebuild
checklist. `/etc/pve` is a cluster filesystem: on a fresh install, restore
individual files (e.g. `qemu-server/*.conf`, `storage.cfg`) into the live
`/etc/pve` rather than untarring over it.
