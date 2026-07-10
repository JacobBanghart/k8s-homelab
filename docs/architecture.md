# Architecture

## Overview

```
Packer (packer/)          Terraform (terraform/)         Ansible (ansible/)
------------------         ----------------------         ------------------
Ubuntu 24.04 ISO      -->  clone template 9000       -->  common
+ containerd               into 3 masters + 3 workers      containerd
+ kubeadm/kubelet/kubectl  on VLAN 30 (k8s-lab),           kubeadm-init (master-0)
  (pinned)                 nvme storage, cloud-init        cni (Cilium)
= template VMID 9000       static IP/hostname/SSH key      join-masters (x2)
                                                            join-workers (x3)
```

## Proxmox layout

- Host today: `prox.mox` (10.1.0.99), PVE 9.1.6, 256 threads / 125GB RAM --
  see "Multi-host provisioning" below for how a second physical host slots
  in without changing the single-host default.
- Existing VMs (do not touch from this repo): 101 (pihole), 102 (dev/k3s,
  managed by `flux/`), 103 (truenas).
- This project's VMs: template 9000 (`k8s-golden`), masters 9101-9103,
  workers 9111-9113.
- Storage: `nvme` pool (fast, same as existing VMs).
- Network: VLAN 30 (`k8s-lab`, 10.4.0.0/24), added via `UnifiTerraform`,
  fully isolated from the primary/friend/iot VLANs.

## Multi-host provisioning (Terraform)

Today this project runs entirely on one physical Proxmox host (`prox`,
10.1.0.99). The `masters`/`workers` maps in `terraform/variables.tf` carry a
per-VM `node` field (defaulting to `var.proxmox_node`, i.e. today's single
host) so a second physical Proxmox host can be brought in by giving some
entries a different `node` value -- no other Terraform code changes needed,
`vms-masters.tf`/`vms-workers.tf` already read `each.value.node` instead of
a single shared `var.proxmox_node`.

**Master anti-affinity is a warning, not a hard rule.** 3 masters only give
real HA if a single physical host's loss can't take down more than one of
them. `terraform/variables.tf` has a `check "master_node_anti_affinity"`
block that warns (via `terraform plan`/`apply` output) if two or more
masters share a `node` value, but deliberately does *not* fail the
plan/apply outright -- a hard `precondition` would break this project's own
current single-host deployment (all 3 masters share `proxmox_node`'s
default today, entirely intentionally). A `check` block was chosen over a
stricter `precondition`/`validation` specifically so it stays informative
without becoming a footgun for the common case. If you do have 2+ physical
hosts, put each master on a different one and the warning goes away.
Workers have no quorum requirement, so spreading them is purely a
capacity/blast-radius call, not a correctness one.

**Template distribution across hosts: per-host Packer build, not shared
storage (for now).** Terraform clones `template_vm_id` (9000) from whatever
`node` a given VM is assigned to -- the template has to actually exist,
under that VMID, on every physical host a VM might land on. Two ways to get
there:

- **Shared storage** (e.g. an NFS or Ceph datastore mounted identically on
  every Proxmox host, `storage_pool` pointing at it) -- build the template
  once, every host can clone it immediately. Cleanest long-term, but this
  project doesn't have shared *Proxmox storage* set up today: the `nvme`
  pool is local-disk-per-host, and the only shared storage that exists
  (a TrueNAS NFS export, `truenas-vzdump`) is registered for VM *backups*
  only (`content type = backup`, see `docs/decisions.md`), not for VM disks
  or templates -- using it for that would need a second `pvesm add nfs`
  registration with `content = images` and hasn't been evaluated for
  performance (NFS vs. local NVMe for active VM disk I/O, not just
  point-in-time backup writes).
- **Per-host Packer build** (the approach documented here): re-run the exact
  same `packer build` with `-var proxmox_node=<second-host>` (or a second
  `.auto.pkrvars.hcl`) against each additional host. `packer/variables.pkr.hcl`
  already parameterizes `proxmox_node`/`storage_pool` per build, so this
  needs no code changes -- just one extra `packer build` invocation per
  host, producing an independent copy of the same VMID/template on that
  host's own local storage. Slightly more manual (re-run on every image
  update, once per host) but needs zero new shared-storage infrastructure
  and matches how this project already treats Packer as a one-shot,
  infrequent step rather than something with its own HA requirements.

**Chosen: per-host template build**, specifically because this project
currently has no shared Proxmox storage pool suitable for VM disks/templates
(only the backup-only TrueNAS export), and standing one up is real new
infrastructure this PR isn't scoped to add or verify. If a second physical
host is added for real, re-evaluate: if `pvesm add nfs ... content=images`
against the existing TrueNAS box turns out to perform acceptably for active
VM disk I/O (not just backups), switching to shared storage removes the
"rebuild the template N times" operational cost.

**Ansible needs no changes for multi-host Proxmox placement.** `hosts.ini`
and `playbook.yml` operate purely on Kubernetes node identity (hostname,
`ansible_host` IP, group membership) -- which physical Proxmox host actually
runs a given VM's compute is invisible to Ansible entirely. Adding a second
Proxmox host changes zero lines in `ansible/inventory/hosts.ini` unless the
*number* of masters/workers also changes (a separate, unrelated axis from
which host they run on).

## Node sizing

| Role    | Count | vCPU | RAM  |
|---------|-------|------|------|
| Master  | 3     | 2    | 4GB  |
| Worker  | 3     | 4    | 8GB  |

Deliberately modest — see `docs/decisions.md` for the capacity analysis
that led to this sizing (the dev VM's CI-burst headroom took priority over
a larger learning cluster).

## Cluster bootstrap flow (Ansible)

1. `common` — hostname, /etc/hosts, chrony, swap-off verification.
2. `containerd` — drift correction (already baked into the Packer image).
3. `kubeadm-init` — `kubeadm init` on `k8s-master-0` only, guarded on
   `/etc/kubernetes/admin.conf`; generates and persists join commands to
   `ansible/.join-commands.sh` (gitignored) for the next two stages.
4. `cni` — installs Cilium via Helm on `k8s-master-0`.
5. `join-masters` — `k8s-master-1`/`k8s-master-2` join via the persisted
   control-plane join command, guarded on `/etc/kubernetes/kubelet.conf`.
6. `join-workers` — all 3 workers join via the persisted worker join
   command, same guard.
7. `metrics-server` — installs metrics-server via Helm on `k8s-master-0`
   (with `--kubelet-insecure-tls`, since this cluster has no real kubelet
   PKI integration) so `kubectl top` and tools like k9s show live CPU/MEM.

Each stage can be re-run independently via `ansible-playbook playbook.yml
--tags <stage>` without redoing earlier stages — the guards make this
safe.

## Sandboxed tenant runtime: Kata Containers

Tenant workloads are isolated by Namespace + NetworkPolicy + ResourceQuota,
but all of that still shares one thing between tenants on the same worker
node: the Linux kernel. A container escape is a kernel exploit away from
every other tenant's pods on that node -- conceptually the same "shared
kernel is the ceiling" risk this project's VLAN-isolation work
(`docs/decisions.md`) dealt with at the network layer, one layer down at
compute.

`clusters/k8s-homelab/kata-containers/` installs `kata-deploy` (upstream's
own installer: a DaemonSet, distributed as an official OCI Helm chart --
see `docs/decisions.md` for why a chart and not raw manifests) and a
`RuntimeClass` named `kata`. Any pod can opt in with
`spec.runtimeClassName: kata` to run inside its own lightweight QEMU
microVM instead of the shared host kernel -- opt-in per workload, not a
cluster-wide default, since it costs real per-pod VM overhead (memory/CPU,
plus nested-virtualization requirements on the underlying node -- see
`docs/decisions.md`).

No Ansible role was added for this. `kata-deploy`'s DaemonSet patches
`/etc/containerd/config.toml` (adding the `io.containerd.kata.v2` runtime
handler) and restarts containerd on each node itself, as part of its own
install/uninstall lifecycle -- this is genuinely a Kubernetes-layer concern
here, not a node-provisioning one, confirmed against upstream's own
kata-deploy docs rather than assumed. The one node-level change this *did*
require went into `ansible/roles/cni/` instead: Cilium's
`socketLB.hostNamespaceOnly: true`, needed for Service resolution to keep
working for Kata pods under `kubeProxyReplacement: true` (see the comment
in `ansible/roles/cni/tasks/main.yml` and `docs/decisions.md`).
