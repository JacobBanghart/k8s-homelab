# Decision log

## Control plane: 3 masters, not 2

Vanilla kubeadm's stacked-etcd control plane needs an odd number of
members for real quorum. 2 masters is *worse* than 1 (either node's loss
breaks quorum). Chose 3 masters for genuine HA and to practice real
etcd/control-plane failover, at the cost of one more VM.

## Distro: vanilla kubeadm, not k3s/RKE2

Goal is "low-budget EKS at home" — maximum transferable knowledge to real
multi-node/multi-host clusters, not the fastest path to a working cluster.
k3s (already running as the separate "Dev Server") and RKE2 were both
considered and rejected for this specific project.

## Checkpointing: idempotent Ansible/Terraform, not snapshots or layered images

"Build from partials" is implemented as re-runnable, tag-guarded Ansible
roles and idempotent Terraform, not Proxmox VM snapshots or incremental
Packer images. Simpler to reason about and matches how you'd actually
operate a real cluster.

## VM provisioning: Packer + Terraform (bpg/proxmox) + Ansible

Three-layer split: Packer bakes the golden image, Terraform clones/sizes
VMs, Ansible configures the OS and bootstraps the cluster. `bpg/proxmox`
was chosen over `Telmate/proxmox` for its actively-maintained cloud-init
support and clone semantics.

## Capacity: trimmed CI runner ceiling instead of naively shrinking the dev VM (2026-07-08)

The dev VM (102) was originally 110 cores/96GB, which looked like massive
over-provisioning from a point-in-time `kubectl top` snapshot (~11GB
actually in use). That was misleading — it's sized to cover the worst-case
resource **limits** of everything on that cluster, dominated by
self-hosted GitHub Actions runners (`ferrix-runner`: 10 replicas @
4c/4Gi; `shared-runner`: autoscaled 1-8 @ 20c/20Gi). Summed cluster-wide
limits were ~107 cores/117.5GB, almost exactly matching the VM's old
allocation.

Instead of shrinking the VM to match steady-state usage (which risked CPU
throttling / OOM-killed CI jobs under real burst load), the CI runner
definitions themselves were trimmed via the `flux/` repo
(`apps/github-runners/runners.yaml`):

- `ferrix-runner`: 10 -> 4 replicas
- `shared-runner`: maxReplicas 8 -> 2, per-pod limit 20c/20Gi -> 8c/8Gi

New CI ceiling: 32 cores/32GB (down from a 200/200 theoretical max). The
dev VM was then resized to 48 cores/64GB — comfortably covering the new
combined cluster-wide limit ceiling (~79 cores/89.5GB) with margin, while
freeing real host capacity (~205 cores/~56GB) for this project.

**Any future change to the CI runner sizing must go through the `flux/`
repo and a Flux reconcile — never `kubectl edit`/`kubectl scale` directly,
Flux will revert it.**

## Control plane endpoint: master-0's IP, no VIP (known limitation -- resolved 2026-07-09)

`control_plane_endpoint` in `ansible/inventory/group_vars/all.yml` still
points directly at `k8s-master-0` (10.4.0.10:6443) -- kubeadm bakes this
into join config and cert SANs at cluster init, so changing it after the
fact would mean re-issuing every node's certs against a new endpoint value,
not just adding one. **A floating VIP (10.4.0.5) was added as a separate,
additive HA path instead** (see "Control-plane VIP: keepalived only, no
haproxy" below) -- new kubectl access and anything not hardcoded to
10.4.0.10 can now go through the VIP and survive master-0 going down,
without needing to touch the original join/cert-SAN baseline. Any *new*
node joining the cluster in the future should use the VIP as its
`--control-plane-endpoint`, not master-0's IP directly.

## Network: dedicated VLAN 30 (`k8s-lab`)

The Proxmox bridge (`vmbr0`) is already VLAN-aware (`bridge-vids 2-100`),
so no new bridge was needed — just a VLAN tag. Existing VLANs in
`UnifiTerraform` are `2` and `20`; `30` was chosen to isolate this
experimental cluster's blast radius from the production pihole/dev-k3s/
TrueNAS VLAN.

## Packer autoinstall bugs found during the first real build (2026-07-09)

The first successful `k8s-golden` template build only came after fixing
four distinct bugs, in order encountered:

1. **GRUB boot_command targeting the wrong UI.** The initial boot_command
   used ESC/F6/backspace keystrokes meant for an inline menu-edit box, but
   this ISO's GRUB dropped straight into the interactive `grub>` shell,
   so the typed text landed as garbled shell input and autoinstall never
   triggered. Fixed by explicitly entering the command-line shell (`c`)
   and issuing `linux`/`initrd`/`boot` as separate, complete commands —
   more verbose but far more reliable than blind menu-edit navigation.
2. **Hardcoded `eth0` in the netplan network config.** This hardware's
   predictable NIC name is `ens18`, not `eth0`, so the DHCP config never
   matched any interface — confirmed via a 15s `tcpdump` on the Proxmox
   bridge showing zero DHCP packets from the VM's MAC at all. Fixed by
   matching `name: "en*"` instead of a hardcoded interface name.
3. **Broken SSH key templating.** `user-data` used a literal
   `__SSH_PUBLIC_KEY__` placeholder string instead of proper Packer
   `templatefile()` interpolation syntax (`${ssh_public_key}`), so the
   real key was never substituted in.
4. **`qemu_agent = true` with no guest agent installed yet.** Packer's
   proxmox-iso builder uses the QEMU guest agent to discover the VM's IP
   for SSH, but `qemu-guest-agent` was only being installed by the first
   *provisioner* script — which itself needs SSH to run. Chicken-and-egg.
   Fixed by adding `qemu-guest-agent` to the autoinstall `packages:` list
   so it's present and running before Packer ever tries to connect.
5. **`sudo: a password is required`.** The `ansible` user had no
   passwordless sudo configured, so Packer's `sudo -S` provisioner
   execute_command failed immediately on the first script. Fixed via an
   autoinstall `late-commands` entry writing
   `/etc/sudoers.d/ansible-nopasswd`.

## Proxmox `hookscript` cannot be set via API token (2026-07-09)

The plan originally called for reusing the existing VMs'
`fix-fw-bridge.pl` hookscript on the new cluster VMs too. Terraform apply
failed with `HTTP 500 - only root can set 'hookscript' config` — Proxmox
hardcodes this restriction to the `root@pam` realm user regardless of any
ACL/role granted to an API token (confirmed: the `terraform` token has
`PVEVMAdmin` + `PVEDatastoreAdmin`, which covers everything else). Dropped
`hook_script_file_id` from both `vms-masters.tf` and `vms-workers.tf`.
This is safe because the new VMs don't set `firewall = true` on their
network device (unlike the 3 existing VMs) — without a firewall-enabled
NIC there's no `fwpr*` proxy interface and thus no bridge-attachment bug
for the hookscript to work around in the first place.

## GitOps: Flux for ongoing addons, not more Ansible roles (2026-07-09)

Once the cluster needed real addons (storage, load balancing, ingress),
it made more sense to bring in Flux than to keep writing one-off Ansible
roles per addon — those are exactly the kind of continuously-reconciled,
declarative state Flux is built for, and it matches how the existing
`flux`-managed k3s "Dev Server" is already operated (consistent workflow,
drift protection, audit trail via git history).

Bootstrapped via `flux bootstrap github --owner=JacobBanghart
--repository=k8s-homelab --branch=main --path=clusters/k8s-homelab
--personal --context=k8s-homelab`, into *this* repo (not folded into the
existing GitLab-hosted `flux/` repo, which manages the separate k3s
cluster) — keeps this project self-contained on GitHub. Future addons
should be added as Flux-managed app directories under
`clusters/k8s-homelab/`, following the per-app directory / `nfs-rwx`
StorageClass / mandatory-resource-limits conventions documented in
`flux/AGENTS.md`, not as new Ansible roles.

## Storage: Rook/Ceph instead of NFS-via-TrueNAS (2026-07-09)

TrueNAS-backed NFS (the pattern the existing `flux`-managed k3s cluster
uses) was considered and rejected: it decouples storage from *k8s node*
lifecycle, but TrueNAS itself becomes a single dependency that also needs
downtime for its own upgrades/maintenance, which would take down every
PVC on this cluster. Rook/Ceph replicates data across the 3 workers' own
disks instead (`replicated.size: 3`, `failureDomain: host` — matching the
3-worker topology for full one-node-loss tolerance), so neither
TrueNAS maintenance nor any single k8s node change affects stored data.
Workers were bumped from 4 vCPU/8GB to 6 vCPU/12GB and given a dedicated
100GB raw disk each (`/dev/sdb`, via Terraform) for OSD backing — real
node-level storage HA, at the cost of real resource overhead (mon/mgr/OSD
daemons on top of whatever workloads run). Deployed via the official
`rook-ceph` + `rook-ceph-cluster` Helm charts (v1.20.2) through Flux.

## Rook/Ceph: needs the separate `ceph-csi-drivers` chart (2026-07-09)

`rook-ceph` chart v1.20.2 installs the `ceph-csi-operator` subchart
(`csi.installCsiOperator: true`, default) — this is not a recent/optional
feature toggle, it's the direction Rook has actually moved: as of
**v1.20.1**, CSI settings were removed entirely from the `rook-ceph`
chart and its operator configmap. The operator now only installs the
`ceph-csi-controller-manager` + CRDs (`drivers.csi.ceph.io`,
`operatorconfigs.csi.ceph.io`); the actual CSI provisioner/node-plugin
pods are created by reconciling a `Driver`/`OperatorConfig` CR instance,
which comes from a **third, separate Helm chart**: `ceph-csi-drivers`,
published in its own repo (`https://ceph.github.io/ceph-csi-operator`,
not `charts.rook.io/release`). Rook's docs are explicit that the chart's
own defaults aren't sufficient — you need the specific override values
Rook publishes per-release (fetched from
`raw.githubusercontent.com/rook/rook/v1.20.2/deploy/charts/ceph-csi-drivers/values.yaml`)
so driver names match what Rook's StorageClasses expect
(`rook-ceph.rbd.csi.ceph.com`, prefixed with the operator namespace).

First pass at this got fixed wrong: `ceph status` reported `HEALTH_OK`
with 3 mons/3 OSDs up, but a test PVC sat `Pending` forever (no
provisioner pods existed at all), and the fix applied at the time was to
set `csi.installCsiOperator: false` to fall back to the pre-1.20 classic
CSI path. That was the wrong direction — it goes against where Rook is
headed, and per the docs may not even be a fully supported path on fresh
v1.20.1+ installs going forward. Corrected to install the
`ceph-csi-drivers` chart properly instead (`clusters/k8s-homelab/rook-ceph/csi-drivers.yaml`),
with `rook-ceph-cluster`'s HelmRelease `dependsOn` updated to wait on it
too, alongside the `rook-ceph` operator.

## Rook/Ceph: `cephBlockPools` override dropped the secret parameters (2026-07-09)

Even after installing `ceph-csi-drivers` and getting `Driver`/`Client
Profile`/`CephConnection` CRs and CSI plugin pods all healthy, PVCs still
failed with `rpc error: ... provided secret is empty`. Root cause: Helm
does not deep-merge list values — it replaces them wholesale. The chart's
own default `cephBlockPools` list entry includes a `storageClass.parameters`
block with the `csi.storage.k8s.io/*-secret-name`/`namespace` fields the
RBD driver needs to actually authenticate against Ceph for volume
operations (separate from the ClientProfile mechanism, which only covers
monitor/cluster connection info). Since `cluster.yaml` overrides
`cephBlockPools` with its own list (to set `failureDomain`/`replicated.size`
for the 3-worker topology), that override silently dropped the chart's
default `parameters` block entirely — no error, no warning, just PVCs
that provision-fail forever. Fixed by explicitly repeating those secret
parameters (`rook-csi-rbd-provisioner`/`rook-csi-rbd-node`, namespace
`rook-ceph`) in the override. Any future override of `cephBlockPools`,
`cephFileSystems`, or `cephObjectStores` needs to carry the chart's full
default block forward, not just the fields being changed.

## Ingress: Traefik, no ACME/Cloudflare (2026-07-09)

Deployed via Flux (`clusters/k8s-homelab/traefik/`), same chart as the
`flux`-managed k3s cluster but deliberately simplified: this cluster is
internal-only on an isolated VLAN with no public domain, so there's no
DNS-01 challenge, no Cloudflare credentials, and no ACME cert storage —
plain HTTP, default `IngressClass`. The `traefik` Service is `type:
LoadBalancer` (chart default) and will sit `<pending>` an external IP
until MetalLB is installed; until then it's reachable via its NodePort
(currently 80→30313, 443→31179, subject to change on redeploy) on any
node's VLAN 30 IP. Installing MetalLB will resolve this without further
changes to the Traefik release itself.

## VM backups: scheduled vzdump to TrueNAS NFS (2026-07-09)

Confirmed via `Obsidian/Infrastructure/Proxmox.md` — no vzdump jobs existed for
*any* VM on the host, old or new. Ceph's `replicated.size: 3` only protects
against losing one worker's disk; all 3 replicas live on VMs on the same
physical Proxmox box, so it's not protection against losing the host itself.
Real off-host recovery needed a copy that actually leaves the host.

Reused an existing (previously unused, 128K) TrueNAS NFS export at
`/mnt/BasicPool/k8s-homelab` — left over from the original NFS-vs-Ceph storage
evaluation — registered as Proxmox storage `truenas-vzdump` (`pvesm add nfs`,
content type `backup` only, prune policy `keep-last=3,keep-daily=7,keep-weekly=4`).
Scheduled via `pvesh create /cluster/backup` (writes to `/etc/pve/jobs.cfg`,
Proxmox's own job mechanism, not a bespoke script) at 03:00 daily, snapshot
mode + zstd compression, covering all 6 VMs (masters 9101-9103, workers
9111-9113) — masters for etcd/control-plane state (not Ceph-replicated at
all), workers for OS/kubelet config (not in git, even though bulk PV data is
Ceph-replicated).

Verified with a real manual run (`vzdump 9101 --storage truenas-vzdump`):
completed in ~99s, produced a real 4.1GB `.vma.zst` archive on the TrueNAS
export. First attempt was accidentally killed by an SSH timeout wrapper
(process received the connection's SIGHUP) — re-ran detached (`nohup ... &`)
to confirm it actually completes end-to-end rather than trusting a truncated
first result.

## Observability: kube-prometheus-stack via Flux (2026-07-09)

Prometheus + Alertmanager + Grafana, all backed by `ceph-block` PVCs (20Gi/2Gi/5Gi)
so data survives pod reschedule, Grafana exposed via Traefik's default IngressClass
at `grafana.k8s-homelab.local`. Grafana admin credentials are a manually-created
Secret (`grafana-admin-credentials`, referenced via `admin.existingSecret`), not
committed to git — same pattern as the k3s cluster's Cloudflare/basic-auth secrets.

Verified with a real target-health check via the Prometheus API
(`/api/v1/targets`), not just "pods are Running": `apiserver`, `coredns`,
`kubelet`, `node-exporter`, and the chart's own components all came back
`up` immediately. Three component ServiceMonitors were disabled rather than
shipped broken:

- `kubeControllerManager`, `kubeScheduler`, `kubeEtcd`: kubeadm binds these
  to `127.0.0.1` by default (security hardening in modern kubeadm) with no
  Service exposing them cluster-wide. Enabling proper monitoring for these
  requires patching the static pod manifests on all 3 masters to bind
  `0.0.0.0` — a real, separate follow-up, not done here since it touches
  control-plane manifests directly.
- `kubeProxy`: same 127.0.0.1-bind issue, and moot anyway since this cluster
  runs Cilium with `kube-proxy-replacement: true` — kube-proxy's own metrics
  aren't meaningful here regardless of whether they're reachable.

## TLS: cert-manager with an internal self-signed CA, not ACME (2026-07-09)

Internal-only VLAN, no public domain, so no Let's Encrypt/DNS-01. Instead:
a bootstrap `selfSigned` ClusterIssuer mints a CA certificate
(`k8s-homelab-ca`, 10y validity), a second ClusterIssuer
(`k8s-homelab-ca-issuer`) signs leaf certs from that CA, and a wildcard
`*.k8s-homelab.local` cert issued through it is set as Traefik's default
`TLSStore` certificate — so any route on `websecure` gets TLS without
needing a per-route cert. Traefik's `web` entrypoint now redirects to
`websecure`. Same CRD chicken-and-egg as `metallb-config`: the
ClusterIssuer/Certificate CRs live in
`clusters/k8s-homelab-config/cert-manager/`, reconciled by their own
retrying Kustomization (`cert-manager-config`) rather than the flat apply
that installs the cert-manager HelmRelease itself.

Hit two bugs getting this in:
1. **`spec.install.crds`/`spec.upgrade.crds` is a Flux string enum**
   (`CreateReplace` etc.), not an object — I initially wrote
   `crds: {enabled: true}` there, confusing it with cert-manager's own
   chart value (`values.crds.enabled`), which is what actually controls
   whether this chart's CRDs get templated (this chart doesn't use Helm's
   native `crds/` directory mechanism at all). The bad object value broke
   dry-run validation for the *entire* `clusters/k8s-homelab` tree's
   apply, not just cert-manager, until fixed.
2. **Traefik's Deployment rollout deadlocked again** — same class of bug
   as the original 3-replica rollout (see below): default
   `maxSurge:1/maxUnavailable:0` tried to schedule a 4th pod, which can
   never satisfy the 1-per-node topology spread constraint. Fixed
   properly this time instead of just manually unsticking it again:
   `updateStrategy.rollingUpdate` set to `maxUnavailable:1, maxSurge:0`
   (terminate-first) so future Traefik config changes roll out without
   manual intervention.

## Control-plane VIP: keepalived only, no haproxy (2026-07-09)

Closed the known limitation from earlier ("control-plane endpoint: master-0's
IP, no VIP"). Considered the standard kubeadm HA reference architecture
(keepalived + haproxy per master) but simplified to **keepalived alone**:
kube-apiserver already binds `0.0.0.0:6443` by default on each master, so a
local haproxy trying to also bind the VIP on port 6443 would conflict unless
apiserver's `--bind-address` were also changed to the node's own IP -- more
moving parts for no real benefit here. Instead the VIP fails over directly
to whichever master's *local* apiserver is healthy (checked via the
standard kubeadm-docs `check_apiserver.sh`, a plain unauthenticated GET to
`https://localhost:6443/`) -- failover-only, not load-balancing across
masters, matching the same model already used for MetalLB/Traefik.

VIP is `10.4.0.5` (outside VLAN 30's DHCP range and the MetalLB pool),
priorities 150/140/130 for master-0/1/2 so master-0 holds it initially and
preempts back after recovering. New Ansible role
`ansible/roles/control_plane_vip/`, tag `control-plane-vip`.

Two bugs hit setting this up:
1. **Assumed interface name `ens18` (from earlier Packer/netplan notes),
   actual interface on these VMs is `eth0`.** keepalived logged a clear
   warning and refused to start; fixed the group var.
2. **`user root` needed on the vrrp_script block** -- keepalived warns
   (but still runs) if no script-execution user is configured, since it
   won't run scripts as the keepalived daemon's own low-privilege context
   by default in newer versions.

**Verified with a real failover test**, not just "service is active":
stopped keepalived on master-0 (initial VIP holder), confirmed the VIP
moved to master-1 within ~4s and `curl` through the VIP still reached the
apiserver, then restarted master-0's keepalived and confirmed it preempted
the VIP back per its higher priority.

Then regenerated the apiserver certificate on all 3 masters to add the VIP
as a SAN: patched the `kubeadm-config` ConfigMap's `ClusterConfiguration`
(`apiServer.certSANs: [10.4.0.5]`), then per master: backed up
`/etc/kubernetes/pki` (kept, not deleted), deleted the old
`apiserver.crt`/`.key` (kubeadm otherwise skips regeneration if a cert
already exists on disk -- it does not diff against updated SANs), reran
`kubeadm init phase certs apiserver --config <cluster-config>`, and forced
the static pod to pick up the new cert via `kubectl delete pod
kube-apiserver-<node>` (a plain manifest move-out/move-back was too fast
for kubelet's file watcher to register as a change -- deleting the mirror
pod is the reliable way to force a static pod restart). Did master-1 and
master-2 first, master-0 (where the working kubeconfig pointed) last, and
confirmed `kubectl get nodes` kept working throughout -- never actually
lost cluster access at any point. Final verification used **real TLS
validation against the cluster's actual CA** (not `-k`) for a request
through the VIP, confirming the new cert is genuinely trusted, not just
"a connection succeeded." Local kubeconfig's `k8s-homelab` cluster entry
now points at the VIP instead of directly at master-0 (old kubeconfig
backed up to `~/.kube/config.bak-before-vip-repoint` first).

## UniFi config moved into this repo, provider upgraded 0.41.3 -> 0.54.1 (2026-07-09)

The standalone `UnifiTerraform` repo was folded into `k8s-homelab/unifi/`
(copied tracked files + local `terraform.tfstate`/`terraform.tfvars`, which
stay gitignored) so this repo is the single thing to hand a friend with a
similar Proxmox box. `UnifiTerraform` is now read-only history -- all
future changes land in `k8s-homelab/unifi/` only.

Bumping the provider (needed for zone-based firewall, see below) turned
out to be a full breaking schema rewrite, not a version bump:
`unifi_network`'s flat `dhcp_enabled`/`dhcp_start`/`dhcp_stop`/`vlan_id`/
network-address `subnet` became nested `dhcp_server{}`/`dhcp_v6_server{}`
blocks and a gateway-IP `subnet`; `unifi_port_forward` restructured into
`wan{}`/`forward{}`/`source_limiting{}` blocks; `unifi_user` (DHCP
reservations) was renamed to `unifi_client`; the `unifi_user_group` data
source was removed, replaced by `unifi_client_qos_rate`. This affected
every file in `unifi/`, not just `firewall.tf`.

**State was incompatible at a deeper level than field renames** --
`terraform show -json`/`plan` couldn't even deserialize several old
resources (`unsupported attribute "dhcp_dns"`, `"dst_port"`,
`"mac_filter_enabled"`). Fix: `terraform state rm` each affected resource,
then `terraform import <addr> <id-or-mac>` fresh under the new provider,
which fetches ground-truth values directly from the live controller
instead of trying to translate old state.

**Trial-and-error diffing against ground truth, not the old file.**
Several fields the old config never set (or set to values that looked
intentional but weren't) showed real diffs once re-imported, because the
new schema's own defaults differ from the old provider's -- applying
blind would have silently changed live behavior:
- `primary` network: `ipv6_interface_type` would have flipped
  `"none"` -> `"pd"` (actually enabling IPv6 prefix delegation on live
  WAN) had I trusted the old file's vestigial `ipv6_pd_start`/`stop`
  values, which turned out to be inert leftovers, not active config.
- `auto_scale`, `lte_lan`, `dhcp_server.conflict_checking`,
  `setting_preference`: all silently default to a *different* value than
  live reality when left unset under the new schema.
- `unifi_wlan`: `iapp_enabled`, `minimum_data_rate_2g_kbps`/`5g_kbps`,
  `group_rekey`, `bss_transition` (for `iot_wifi` specifically, which
  never declared it) -- same class of issue, real 802.11 behavior fields,
  not cosmetic.
Fixed by dumping `terraform show -json` after each fresh import and
pinning every field that showed a diff to the exact live value, rather
than guessing or copying the old file's stated intent.

**`unifi_client` (renamed from `unifi_user`) adopts by MAC, no import
needed** for most -- its `allow_existing` (default `true`) lets a plain
resource block take over an existing device by MAC address. One
exception: `proxmox`'s adopt-via-create failed with
`api.err.FixedIpAlreadyUsedByClient` (a self-conflict, since the client
already had that exact fixed IP) -- fixed by importing it directly via
MAC instead of letting create/adopt run.

**Pi-hole API rate-limiting** repeatedly interrupted `plan`/`apply` runs
during this work (`too many session requests`) -- worked around by
`-target`-ing just the `unifi_*` resources, since the two providers'
resources are independent of each other.

Confirmed two provider-version-specific bugs along the way:
- `v0.43.0` (the minimum version with firewall zones) has a real bug:
  `unifi_firewall_zone` create fails with `Unrecognized field
  "default_zone"` -- fixed in the `v0.52.4` changelog. Had to bump further
  to `v0.54.1` to get a working zone create.
- Bumping from `0.43.0` to `0.54.1` broke `ipv6_ra_preferred_lifetime`/
  `ipv6_ra_valid_lifetime` (plain number -> Go duration string, e.g.
  `"14400s"` normalized to `"4h0m0s"` by the controller) and exposed the
  same stale-state decode issue as above for the *remaining* legacy
  `unifi_firewall_rule` resources (iot/friend rules, left alone this
  round) -- their stored `src_mac = ""` was rejected by the newer
  version's stricter MAC-format validator. Fixed the same way: remove +
  reimport fresh.

End state: `unifi_network`/`unifi_port_forward`/`unifi_wlan`/
`unifi_client` all confirmed zero-diff against live reality via
`terraform plan`. See the next entry for what happened attempting the
actual zone-based firewall policy on top of this.

## VLAN isolation is not actually enforced (2026-07-09, confirmed not fixed)

Live-tested from a k8s-lab (VLAN 30) node: `ping`/reachability to the dev server
(10.1.0.34), TrueNAS (10.1.0.45), and Pi-hole (10.1.0.142) all succeeded with
0% packet loss — the `unifi_firewall_rule.block_k8s_lab_to_*` rules in
`UnifiTerraform/firewall.tf` are not blocking anything, despite showing
`enabled: true` via the UniFi API.

Root cause: this UDM Pro has migrated to UniFi's **zone-based firewall**
(confirmed via `GET /proxy/network/v2/api/site/default/firewall-policies`,
which returns live zone policies including a predefined `"Allow All Traffic"`
policy between zones). The `unifi_firewall_rule` Terraform resource writes to
the **legacy** `LAN_IN` ruleset (`GET /proxy/network/api/s/default/rest/firewallrule`),
which still accepts writes for backward compatibility but is no longer the
active enforcement path once zone-based firewall is in effect — so the k8s-lab
block rules are silently inert.

**Update (2026-07-09): attempted real fix, caused a live incident, reverted.**

The `ubiquiti-community/unifi` provider version needed for zone-based
firewall support (`unifi_firewall_zone`/`unifi_firewall_policy`) is
`v0.43.0+` (`0.41.3` predates it entirely). Upgrading turned out to be a
full breaking schema rewrite across every resource in `unifi/` (not just
firewall-related ones) -- see the migration writeup below. After migrating
everything else cleanly and verifying zero unintended diffs, the actual
fix attempt was:

1. `data "unifi_firewall_zone" "internal"` -- looked up the existing zone
   (confirmed named `"Internal"`, currently containing all 4 networks:
   primary/friend/iot/k8s_lab).
2. `resource "unifi_firewall_zone" "k8s_lab"` -- a new zone containing only
   the k8s-lab network, removing it from Internal.
3. `resource "unifi_firewall_policy" "block_k8s_lab_egress"` -- one
   zone-level BLOCK policy, k8s-lab zone -> Internal zone, ANY/ANY.

Applying steps 2-3 **broke all connectivity to VLAN 30 in both
directions**, not just the intended one-way block -- confirmed via a live
outage: `kubectl` (through the control-plane VIP) and plain ICMP to every
k8s-lab host started timing out immediately after apply, while the primary
VLAN and gateway stayed fully reachable (ruling out a broader network
issue). Root cause: UniFi's zone-based firewall has **no implicit "allow"
for a zone-pair with no explicit policy** -- the built-in zones
(Internal, Guest, etc.) ship with a predefined `"Allow All Traffic"`
policy per pair already configured, but a *newly created custom zone* has
none, so creating one and adding only a BLOCK policy made the reverse
direction (Internal -> k8s-lab, needed for `kubectl`/SSH management
access) silently default-deny too.

Added a fourth resource, `unifi_firewall_policy.allow_internal_to_k8s_lab`
(ALLOW, Internal -> k8s-lab, ANY/ANY, `create_allow_respond = true`),
immediately after diagnosing this. Confirmed via the live API
(`GET /proxy/network/v2/api/site/default/firewall-policies`) that all
three policies existed, were `enabled: true`, and had the expected
zone IDs/action/direction -- but connectivity was **still not restored**
even 20+ seconds after apply, with a subsequent `terraform apply` showing
zero pending changes (i.e. not a stale-apply issue). Root cause of that
specific residual failure was not identified before the decision was made
to fully revert rather than keep experimenting against a live management
network.

**Reverted**: destroyed the zone and both policies
(`terraform destroy -target=...` x3), confirmed via live `ping` to
10.4.0.10 and `kubectl get nodes` (all 6 nodes `Ready`) that connectivity
was fully restored, then removed the resources from `firewall.tf` too so
config matches live reality (a stray `terraform apply` won't silently
recreate the same outage). `firewall.tf` is back to the same
non-functional legacy `unifi_firewall_rule` state as before this attempt.

**Not fixed. Treat VLAN 30 as unisolated from the rest of the network**
for any threat-modeling purposes. Re-attempting this needs, at minimum:
a way to test zone/policy changes without risking management-network
access mid-change (e.g. an out-of-band console session held open before
applying, so a bad change can be immediately reverted without needing
network access to the box doing the reverting), and a clearer
understanding of why the explicit ALLOW policy didn't restore access
before assuming the fix (zone + block + allow) is even structurally
correct.

**Update (2026-07-09, later the same day): fixed for real, no outage.**

Reviewed the live policy set from the failed attempt (before reverting)
and found the actual root cause: the BLOCK policy's `connection_state_type`
defaulted to `ALL`, matching unconditionally regardless of connection
state -- including *return* traffic (response packets, TCP ACKs, ping
replies) for connections Internal itself initiated into k8s-lab. An
unscoped "block everything from k8s-lab to Internal" also blocks the
reverse leg of the "Internal can reach k8s-lab" traffic that's supposed to
stay open, since nearly all two-way communication needs that return leg --
this fully explains why both directions broke even though only one was
supposed to be blocked.

Tried to fix this properly by scoping the BLOCK policy to
`connection_state_type = "CUSTOM"` / `connection_states = ["NEW"]` (block
only new connections initiated *from* k8s-lab) -- but both fields are
**read-only/computed** in the installed provider version (`0.54.1`):
`"Managed by the UniFi controller; the provider round-trips it"`. Not
settable via Terraform at all in this version.

Realized a simpler design doesn't need that field: new custom zones
default-deny any zone-pair with *no explicit policy at all* (that's what
caused the original outage). So creating the k8s-lab zone and adding
*only* one ALLOW policy (Internal -> k8s-lab, `create_allow_respond =
true`, which auto-generates the paired RESPOND_ONLY return-traffic policy)
already leaves k8s-lab -> Internal for *new* connections with no explicit
policy -- which defaults to deny. No BLOCK policy needed at all. Final
`firewall.tf` state: `data.unifi_firewall_zone.internal` +
`unifi_firewall_zone.k8s_lab` + one
`unifi_firewall_policy.allow_internal_to_k8s_lab`.

**Verified with a tight-loop live test this time** (checking within 1-3
seconds of apply, not waiting 20+ seconds): `ping` to 10.4.0.10 and
`kubectl get nodes` both worked immediately after apply, no outage.
Then the actual isolation test: `ping` from a k8s-lab node to the dev
server (10.1.0.34), TrueNAS (10.1.0.45), and Pi-hole (10.1.0.142) all
returned **100% packet loss** (previously 0%) -- confirmed genuinely
enforced this time. Full cluster health swept afterward (`kubectl get
nodes`, a real `https://grafana.k8s-homelab.local` request, checked for
any non-Running pods cluster-wide) -- all clean.

**Fixed. k8s-lab is now actually isolated**: it cannot initiate new
connections to the primary/friend/iot networks, while Internal (this
machine, kubectl, SSH) retains full management access into k8s-lab.

## Log aggregation: Loki + Promtail (2026-07-09)

SingleBinary Loki (filesystem storage, `ceph-block` PVC, 7d retention) +
Promtail DaemonSet, added to the existing `monitoring` namespace/Flux app
pattern. Wired into Grafana via `grafana.additionalDataSources`.

Two things worth knowing if this trips someone up again:
- **Promtail logged `connect: operation not permitted` to Loki on every
  node for the first ~30s after install**, then went silent. This looked
  alarming (looked like a Cilium policy or capability issue) but was
  transient -- a plain `curl` pod reached Loki fine at the same time, and
  querying Loki directly (`/loki/api/v1/label/job/values`) confirmed logs
  from every namespace, including `monitoring/promtail` itself, were
  already flowing. Root cause not confirmed, but harmless in practice --
  don't panic if you see this again, verify against Loki's own API before
  assuming it's broken.
- **Updating Grafana's HelmRelease values (e.g. adding this datasource)
  can hit the same RWO-PVC rollout stall as the Traefik topology-spread
  issue earlier**, for a different reason: Grafana runs a single replica
  on a `ReadWriteOnce` PVC, so a rolling update's new pod can't mount the
  volume until the old pod fully releases it, and the default
  surge-first strategy tries to bring up the new pod before killing the
  old one. Fix is the same pattern as before: `kubectl delete pod
  <old-grafana-pod>` to force the release. Also confirmed the datasource
  ConfigMap (`kube-prometheus-stack-grafana-datasource`) updates
  immediately on `helm upgrade` regardless -- Grafana just doesn't
  re-read it until the pod actually restarts.

## Multi-host Proxmox provisioning: per-VM `node`, warning not a hard rule (2026-07-09)

Parameterized `terraform/variables.tf`'s `masters`/`workers` maps with a
per-entry `node` field (defaulting to `var.proxmox_node`, today's single
real host) so the worker pool -- and masters, for real HA -- can span more
than one physical Proxmox host without changing the single-host default
behavior at all. `vms-masters.tf`/`vms-workers.tf` now read
`each.value.node` instead of the old shared `var.proxmox_node`.

**Anti-affinity as a `check` block, not a `precondition`.** 3 masters only
give real HA if losing one physical host can't take out more than one of
them. A hard `precondition` failing the plan/apply when two masters share a
`node` would be the "correct" strict answer, but it would also immediately
break this project's own actual current deployment (single host, all 3
masters intentionally share the same node). Terraform's `check` block
(warns via plan/apply output, never blocks) was the better fit here: it
surfaces the real risk the moment someone edits `masters` for multi-host
without actually spreading them, but doesn't turn "haven't gotten a second
host yet" into a broken `terraform plan`.

**Template distribution: per-host Packer build, not shared storage.**
Considered registering a shared Proxmox storage pool (e.g. `pvesm add nfs`
against the existing TrueNAS box, same mechanism as the `truenas-vzdump`
backup target, but with `content=images` instead of `content=backup`) so
one `packer build` produces a template every host can clone. Rejected for
now: that TrueNAS export is currently registered backup-only, and
repurposing/extending it for live VM disk and template I/O is new
infrastructure with real unknowns this PR doesn't touch or verify
(NFS latency/throughput under active clone-and-boot, not just nightly
backup writes). Landed on the simpler alternative instead -- re-run
`packer build -var proxmox_node=<host>` once per additional physical host,
producing an independent copy of the same template VMID on that host's own
local `nvme` storage. Real operational cost (rebuild once per host on every
image update, N times instead of once), but zero new shared-storage
dependency. If a second host materializes for real, re-evaluate whether
`content=images` on the TrueNAS NFS export performs well enough to be worth
switching to.

**Ansible needed no changes at all.** `hosts.ini` and `playbook.yml` are
already Kubernetes-node-identity-based (`hosts: masters`/`hosts: workers`),
with zero awareness of which physical Proxmox host backs a given VM's
compute -- confirmed by reading through `playbook.yml`'s host patterns
rather than assumed, since the task description flagged this as something
to actually verify.

## Kata Containers: per-pod VM isolation for tenant workloads (2026-07-09)

Every tenant container on a worker node currently shares that node's Linux
kernel with every other tenant's pods -- Namespace/NetworkPolicy/
ResourceQuota isolate at the Kubernetes API and network-policy level, but a
kernel exploit in one tenant's pod is still a path to every other tenant on
that node. Conceptually the same "shared kernel is the ceiling" problem
this project's VLAN-isolation work was solving one layer down, at the
network layer, for VLAN 30 as a whole.

Added `clusters/k8s-homelab/kata-containers/`: `kata-deploy` (upstream's own
installer for the Kata runtime) plus a `RuntimeClass` named `kata`, so any
pod can opt in via `spec.runtimeClassName: kata` to run inside its own
lightweight QEMU microVM instead of the shared host kernel. Opt-in, not
cluster-wide default -- real per-pod overhead (memory/CPU for the microVM
itself, plus the node needing nested virtualization -- see the open
question below).

**Install method: kata-deploy's official OCI Helm chart, not vendored raw
manifests.** Historically kata-deploy was `kubectl apply -f` against raw
DaemonSet/RBAC YAML fetched from the kata-containers repo. As of the
`3.32.0` release (verified via `tools/packaging/kata-deploy/helm-chart/` in
that tag, and `helm show values` against the published chart at
`oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy`), upstream
now publishes and documents an official Helm chart as the primary install
path. This fits this repo's existing pattern far better than vendoring raw
manifests would (every other addon here is a Flux `HelmRelease`) and gets
config knobs (`shims`, `runtimeClasses.createDefault`/`defaultName`,
`k8sDistribution`) as real typed values instead of hand-edited env vars on
a copy-pasted DaemonSet spec. Flux consumes it via `OCIRepository` +
`HelmRelease.spec.chartRef` (the currently-recommended pattern for OCI
charts -- `HelmRepository` with `type: oci` still works but upstream Flux
docs call it maintenance-mode), pinned to the exact `3.32.0` tag, matching
this repo's existing convention of exact chart-version pins (e.g. Loki's
`6.55.0`) over floating ranges.

**Only the `qemu` shim is enabled** (`shims.disableAll: true` +
`shims.qemu.enabled: true`). kata-deploy ships shims for Firecracker, Cloud
Hypervisor, NVIDIA GPU passthrough, and confidential-computing (SEV/TDX)
hardware, none of which exist on this cluster's plain KVM-capable Proxmox
VMs -- enabling them would just be dead DaemonSet install work and
extra RuntimeClasses nobody can use.

**`runtimeClasses.createDefault: true` + `defaultName: "kata"`** is what
actually produces the `kata`-named `RuntimeClass` (in addition to the
per-shim `kata-qemu` one the chart always creates when a shim is enabled)
-- picked specifically so workloads opt in with the short, memorable
`runtimeClassName: kata` instead of needing to know the shim name.

**Cilium/containerd compatibility, checked rather than assumed:**
- **Cilium + Kata is a documented-supported combination**
  (docs.cilium.io/en/stable/network/kubernetes/kata/), via Kata's
  tc-redirect-tap networking model (a tap device inside the pod's VM,
  TC-mirrored to/from the veth pair Cilium already manages in the "outer"
  netns). Cilium's own docs flag a real, known tradeoff worth stating
  plainly: a ~46% cross-node throughput drop for Kata pods vs. Calico in
  published benchmarks, and an MTU-propagation gap (the pod only inherits
  the outer device MTU, not the adjusted route MTU) that upstream's
  workaround is a per-pod initContainer, not a cluster-wide Cilium setting.
  Not fixed here -- noted as a known limitation for anyone actually running
  latency/throughput-sensitive tenant workloads under `kata`.
- **`socketLB.hostNamespaceOnly: true` was added to the Cilium Helm values**
  in `ansible/roles/cni/tasks/main.yml`, per the same Cilium/Kata doc page:
  with `kubeProxyReplacement: true` (already this cluster's setting),
  Cilium's socket-level load balancer intercepts a pod's `connect()`/
  `sendmsg()` calls in the *outer* netns -- a Kata pod's actual workload
  runs inside the microVM's own kernel, one layer below where that
  interception happens, so it never benefits from it and Service resolution
  for Kata pods needs the per-veth eBPF datapath instead. This only takes
  effect on a *fresh* Cilium install (the Ansible task is guarded on
  "not already installed" like the rest of `cni`); an already-bootstrapped
  live cluster would need a manual `helm upgrade` to pick this up --
  not done here since this PR doesn't touch live infrastructure.
- **containerd config changes are handled entirely by kata-deploy itself,
  not a new Ansible role.** Confirmed via upstream kata-deploy
  documentation/manifests rather than assumed: the DaemonSet mounts
  `/etc/containerd/` from the host, edits `config.toml` to add the
  `io.containerd.kata.v2` runtime handler(s), and restarts containerd
  itself (via `hostPID: true` to reach the host's PID/mount namespace) as
  part of its own install/uninstall lifecycle. This is genuinely a
  Kubernetes-layer (Flux-managed) concern, not a node-provisioning one --
  `ansible/roles/containerd/` was deliberately left untouched.

**Open question / not independently verified: nested virtualization on the
physical Proxmox host.** Kata's `qemu` shim needs the worker VM itself to
expose VT-x/AMD-V to its guest kernel (`/dev/kvm` inside the k8s-worker VM),
which requires the *physical* Proxmox host's own KVM kernel module loaded
with nested virtualization enabled (`kvm_intel nested=1` or
`kvm_amd nested=1`) -- a host-level setting this repo's automation doesn't
control and this PR has no credentials/access to check on the real
`prox.mox` host. Workers already use `cpu.type = "host"` (passes through
host CPU features, including VMX/SVM, if present), so if nested
virtualization is enabled at the host kernel level this should just work;
if not, `kata-qemu` pods will fail to start with a clear KVM-related error.
**Verify `cat /sys/module/kvm_intel/parameters/nested` (or `kvm_amd`) on
`prox.mox` is `Y`/`1` before relying on this in anger** -- not done as part
of this PR. Deliberately left `node-feature-discovery.enabled: false` (the
chart's own mechanism for gating scheduling on detected VT-x/AMD-V
support) rather than standing up a whole NFD deployment just for this one
check; the tradeoff is a real-but-clear KVM failure on an unsupported node
instead of a silent scheduling skip.

**Also not verified/sized: per-pod Kata VM overhead against the current
worker sizing** (6 vCPU/12GB, already trimmed once for Rook/Ceph -- see
"Storage: Rook/Ceph" above). Kata's default per-pod overhead
(cpu/memory reserved for the microVM itself, on top of whatever the
workload requests) is real and additive on an already-modest node. Left
unmeasured rather than guessed at -- same reasoning as the CI-runner
capacity work: don't resize off a point-in-time guess, measure real usage
once Kata pods actually run, then revisit sizing with data if it's tight.
