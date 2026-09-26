# Plan: collapse to a single-node kubeadm VM (drafted 2026-09-26)

## Why

prox has 125 GiB RAM. The 6 cluster VMs pin ~88 GiB of it (host RSS) while
the guests actually use ~39 GiB, leaving ~14 GiB free on the host. The
causes, measured 2026-09-26:

- **VFIO passthrough pins guest RAM.** Each worker has a 990 Pro passed
  through for Ceph (`hostpci0`, set by hand outside Terraform), so QEMU
  locks all 24 GiB up front. Ballooning and free-page reporting cannot
  return anything. 72 GiB are held for ~25 GiB of use.
- **Per-node tax x6.** Guest kernel + kubelet + containerd per VM; cilium,
  promtail, CSI node plugins, metallb speakers per node; 3x kube-apiserver
  (3.8 GiB total) + 3x etcd.
- **Ceph:** 6.7 GiB used / 7.8 GiB requested, for 151 GiB of data kept
  3x on one motherboard. `osd_memory_target` is 4 GiB/OSD, so this can grow.
- **HA duplicates on one box:** 2x CNPG clusters at 3 instances (authentik's
  DB is stored 9x once Ceph's 3x replication is included), Grafana x3,
  Vault x3, Traefik x3.
- **Requests vs use:** 49 GiB requested cluster-wide; ARC runners alone
  request 13.7 GiB and use 1.5.

Target: **one 40 GiB VM** (~20 GiB real use, ~26 GiB requests after
cleanup) + ~4 GiB ZFS ARC on the host. **~45 GiB returned to the host**,
plus NVMe usable capacity going from 3.3 TiB (Ceph 3x) to ~7.2 TiB (ZFS
mirrors).

This reverses two entries in `decisions.md` ("3 masters, not 2", "Rook/Ceph
instead of NFS"). The multi-node-practice goal is traded for capacity. A
throwaway 3-node cluster can still be built from the same Packer/Terraform/
Ansible code when that practice is wanted.

## Decisions

| Question | Choice | Why |
|---|---|---|
| k3s vs kubeadm | **kubeadm, control-plane taint removed** | k3s saves ~1 GiB. kubeadm keeps the existing Packer/Terraform/Ansible pipeline and "real k8s". |
| VM vs LXC | **VM** | See below. |
| Disk passthrough | **None.** Disks go back to the host as ZFS; the VM gets a normal virtual disk (a zvol) | Passthrough is what pins RAM and blocks free-page reporting. Host ZFS gives redundancy + snapshots. |
| Ballooning | `memory_min == memory` (balloon device present, never inflates) | Stops the kubelet-capacity-vs-real-RAM trap (see memory note on balloon RAM). `free-page-reporting=on` is already emitted by qemu-server 9.1, so freed guest pages still return to the host. |
| Storage in-cluster | `local-path-provisioner`, default StorageClass | Near-zero RAM. On one node RWO volumes can be mounted by several pods, so the two CephFS RWX caches don't need RWX. |
| Host pool | Striped mirrors: 2x (990 Pro + 990 Pro), ~7.2 TiB | Mirrors are the Proxmox-recommended layout for VM zvols/DBs, and can be grown one pair at a time. raidz1 x4 (~10.8 TiB) is the alternative if capacity matters more than IOPS. |
| VM size | 32 vCPU / 40 GiB, `numa=1`, `cpu=host` | Host has 256 threads, so CPU is free. 40 GiB covers ~26 GiB of requests + homestead heap growth + CI bursts. |
| Control-plane endpoint | A DNS name (e.g. `k8s-api.lab`) → node IP, **not** a raw IP or VIP | kubeadm bakes the endpoint into certs (lesson from the 10.4.0.10 entry in decisions.md). A name keeps adding nodes later possible. No keepalived. |
| Names | infra `clusters/homelab/` + `clusters/homelab-config/` (this repo); apps `clusters/homelab-apps/` (flux repo); kube context `homelab` | New paths let old and new clusters run side by side. The old paths get deleted at decommission. |

### Why not an LXC

LXC would save a little more (no guest kernel; page cache shared with the
host), maybe 2–4 GiB. But kubeadm + Cilium in LXC needs a **privileged**
container with nesting, `/dev/kmsg`, unconfined AppArmor, host-loaded
kernel modules, shared sysctls, and Cilium loading eBPF into the **host**
kernel. That is effectively root on prox, which also runs TrueNAS. This
cluster runs GitHub Actions jobs for a repo you don't own
(`ReclaimerGold/rdn-pve-manager`), so that isolation matters. It would also
tie k8s kernel requirements to Proxmox kernel upgrades. Once passthrough is
gone, a VM with free-page reporting gets most of the elasticity anyway.

## Phase 0: make room on the host (old cluster, ~1 evening)

The new VM must run next to the old cluster during migration; only ~14
GiB is free today.

1. **flux repo:** `github-runner/runners.yaml`: ferrix-runner request 1Gi
   → 256Mi, dind 256Mi → 64Mi (idle use is ~115 Mi). Frees ~10 GiB of
   requests. *(Decide concurrency, see Open decisions.)*
2. **This repo:** Grafana 3 → 1 (drop the DoNotSchedule topology spread),
   Traefik 3 → 1.
3. **Terraform:** masters 6144 → 4096, workers 24576 → 16384. The VMs need
   a reboot to apply; do one at a time and wait for `ceph -s` HEALTH_OK and
   etcd healthy between nodes. **First reconcile drift:** 9112/9113 have
   `balloon` 20480/19456 set by hand while Terraform says 24576.
4. Expected host free: ~14 + 6 + 24 ≈ **44 GiB**.

## Phase 1: build the node (no impact on the old cluster)

1. **Terraform:** new `vms-single.tf` + `var.single_node` (VMID 9121, VLAN
   30, new IP e.g. 10.4.0.30, 32c/40 GiB, `memory_min` = `memory`, 200 GB
   `scsi0` with `discard=on`, `ssd=1`, `iothread=1`). **Do not shrink the
   existing `masters`/`workers` maps.** Terraform would destroy the live
   VMs. Stage the disk on `etcd-fast` (nvme4n1, 3.7 TB free); it moves to
   ZFS in Phase 5.
2. **Ansible:** `inventory/single.ini` (host in `masters` +
   `control_plane_init`, empty `workers`/`control_plane_join`) and group_vars
   overriding `control_plane_endpoint` to the DNS name. Skip the
   `control_plane_vip` stage. Add an `untaint` step (new tiny role, or in
   `kubeadm_init` when `groups['workers']` is empty) running
   `kubectl taint nodes --all node-role.kubernetes.io/control-plane-`.
   Kubelet: set `systemReserved`/`kubeReserved` (~1 GiB each) and hard
   eviction `memory.available<1Gi`, since there's no other node to fail
   over to.
3. Cilium: `k8sServiceHost` → the endpoint name. Hubble stays.
4. `flux bootstrap github ... --path=clusters/homelab --context=homelab`.

## Phase 2: infra on the new cluster (old cluster still serving)

Copy `clusters/k8s-homelab{,-config}` → `clusters/homelab{,-config}`,
then:

- **Drop:** `rook-ceph/`, `ceph-backup/`, the ceph alerts/ServiceMonitor,
  and the dashboard LB (.203).
- **Add:** `local-path-provisioner` (default SC, path on the VM disk).
- **storageClass** `ceph-block` → `local-path` everywhere (14 files here, 16
  in the flux repo).
- **Replicas → 1 and anti-affinity removed:** Vault (`server.ha.replicas: 1`,
  keep raft + KMS unseal), Traefik, Grafana, grafana-postgres CNPG
  (`instances: 1`; `podAntiAffinityType: required` would block it
  otherwise).
- **Conflict guards while both clusters run:**
  - MetalLB: staging pool `10.4.0.230-10.4.0.239` (old cluster owns
    .200–.220).
  - external-dns: **not deployed yet** (same zone + `txtOwnerId`, both
    would fight).
  - cert-manager: copy the existing TLS secrets from the old cluster before
    creating Ingresses, so cert-manager reuses them instead of racing DNS-01
    challenges.
- **Vault first:** everything else needs ESO → Vault. Take `vault operator
  raft snapshot save` on the old cluster and `snapshot restore -force` into
  the new 1-replica Vault (same AWS KMS key auto-unseals it). Verify ESO
  syncs secrets.
- Monitoring: Prometheus history is disposable. Start fresh (or copy the
  PVC if you care about it).

## Phase 3: apps staged + data pre-seeded (old cluster still serving)

Copy flux `clusters/k8s-homelab-apps` → `clusters/homelab-apps` (Flux
auto-generates the kustomization, so a copy is enough). Point the new
`flux-apps` Kustomization at it. Changes:

- storageClass → `local-path`; the two `ceph-filesystem` runner caches → RWO
  `local-path`, or just recreate them empty.
- authentik-postgres `instances: 1`.
- **Keep at 0 until cutover:** ARC runners (they'd double-register against
  GitHub) and homestead (Minecraft world must not diverge).
- **Warm copy** each file PVC with `pv-migrate` across contexts
  (`k8s-homelab` → `homelab`, rsync strategy) while the old apps keep
  running. Large volumes first: immich (250Gi claim), homestead, nextcloud,
  files, jellyfin.
- Test each app via the staging LB IP + a hosts-file entry.

## Phase 4: cutover (maintenance window, ~2–3 h)

1. Old: `flux suspend kustomization flux-apps` and scale app workloads to
   0 (Flux would revert the scale-down otherwise).
2. **Databases:** bootstrap the new CNPG clusters with `bootstrap.initdb.import`
   from the old ones (logical dump: authentik + grafana). Immich and
   nextcloud run plain Postgres Deployments on a PVC, so `pg_dump` →
   `pg_restore` them into the new pods (not a file copy of a live data
   dir). Doing this now captures a consistent final state.
3. Final `pv-migrate` pass (rsync delta only, so fast).
4. Old: `flux suspend kustomization flux-system`, scale external-dns
   and the ARC controller to 0, delete the MetalLB `IPAddressPool` (frees
   .200–.203).
5. New: switch the MetalLB pool to `10.4.0.200-10.4.0.220` (Traefik .200,
   Mosquitto .201, homestead .202 as before), deploy external-dns with
   the **same** `txtOwnerId: k8s-homelab` so it adopts the existing records.
   Public DNS points at the WAN IP (port-forward → .200), so nothing
   externally should change.
6. Enable runners + homestead. Checklist: authentik login, Vault/ESO, every
   ingress, HA ↔ Mosquitto, Minecraft connect, a runner job, Immich
   upload.

**Rollback:** reverse steps 4–5 and resume Flux on the old cluster. Its
data was only scaled down, never deleted.

## Phase 5: backups: in place **before** decommission

The `ceph-rbd-offsite-backup` CronJob is Ceph-only and goes away.
Replacement:

- **Host-level (new, local, free):** sanoid snapshots of the VM zvol
  (hourly/daily) + syncoid to TrueNAS `HDDPool`. This also fills the gap that
  HDDPool has no snapshot/replication tasks today.
- **Offsite:** a nightly in-cluster restic CronJob backing up the
  local-path root (hostPath mount, file-level) to the existing S3 repo, tag
  `local-path`, host `homelab`. Postgres is not file-level safe: add
  CNPG backups (barman-cloud to S3) or a `pg_dump` pre-step.
- Old `ceph-rbd` snapshots age out under the existing 7d/5w/6m retention.
  Leave them. Glacier IR has a 90-day minimum, so deleting early saves
  nothing.
- Prove one restore of a small PVC before Phase 6.

## Phase 6: decommission (after ~1–2 weeks stable)

1. Terraform: remove `masters`/`workers` maps → destroys 9101–9103,
   9111–9113. Also delete templates 9000/9001 if unused.
2. On prox: confirm no `hostpci` remain, then wipe the three 990 Pros
   (`wipefs -a`, `sgdisk --zap-all`).
3. Create the pool: `zpool create -o ashift=12 fast mirror <990a> <990b>`,
   `autotrim=on` (NVMe on PCIe, **not** behind the SAS3216 HBA, so the TRIM
   fault doesn't apply; still don't re-enable the host `fstrim.timer`),
   `compression=lz4`; `zfs_arc_max` = 4 GiB (currently `0` = unlimited
   default); `primarycache=metadata` on the VM dataset (the guest already
   caches, avoid double caching). Add as Proxmox `zfspool` storage.
4. `qm disk move 9121 scsi0 fast` (online).
5. `etcd-fast` is now empty: remove the storage, wipe nvme4n1, `zpool add
   fast mirror <990c> nvme4n1`.
6. Repo cleanup: delete `clusters/k8s-homelab{,-config}` here and
   `clusters/k8s-homelab-apps` + stale `apps/github-runners` in flux; update
   README ("single-node"), `architecture.md`, and add a decisions.md entry
   superseding "3 masters" and "Rook/Ceph". Update the Obsidian notes
   `Infrastructure/k8s-homelab.md` and `Infrastructure/Backup Strategy.md`
   (the latter documents the Ceph backup job and restore steps in detail).

## Open decisions

1. **ferrix-runner concurrency.** 10 fixed replicas at a 4 GiB limit =
   40 GiB worst case, the whole VM. Idle cost is fine once requests drop,
   but 10 concurrent heavy builds would cause OOM kills/evictions on one
   node. Options: cap to 4–6 replicas (decisions.md already cut 10 → 4 once;
   it's back at 10), or lower the limit, or accept the risk.
2. Pool layout: mirrors (default) vs raidz1.
3. VM memory: 40 GiB default; 32 GiB possible if runners are capped.
