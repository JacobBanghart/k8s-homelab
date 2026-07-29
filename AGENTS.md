# Agent notes for k8s-homelab

## Generic guidance (applies to any fork of this repo)

- Cluster is vanilla kubeadm (not k3s/RKE2), 3 masters for real
  stacked-etcd HA quorum, Cilium as CNI.
- Ansible roles must stay idempotent and safely re-runnable per-tag
  (`common`, `containerd`, `kubeadm-init`, `cni`, `join-masters`,
  `join-workers`) — that's the "build from partials" requirement this
  project is designed around, in place of image/snapshot layering.
- terraform state and `*.tfvars` (except `*.tfvars.example`) are gitignored
  — never commit real credentials or state.
- Once Flux is bootstrapped, ongoing addons (StorageClass/CSI, MetalLB,
  ingress, etc.) should go through Flux — new app directories under
  `clusters/<your-context-name>/`, one per app: Namespace ->
  HelmRepository/GitRepository -> HelmRelease/Kustomization. Split any
  config that depends on an addon's own CRDs (which don't exist until
  that addon has reconciled once) into a matching directory under
  `clusters/<your-context-name>-config/` with its own Kustomization and
  `dependsOn` — see the existing `cert-manager`/`cnpg`/`metallb` pairs for
  the pattern. Don't add addons via ad-hoc Ansible tasks — that's a
  one-off escape hatch, not the ongoing pattern.
- Do NOT manually edit `clusters/<your-context-name>/flux-system/gotk-*.yaml`
  — those are generated and managed by `flux bootstrap`.
- Files/manifests tagged `PERSONALIZE:` in a comment contain domain names,
  emails, or account-specific values baked in as a worked example for the
  original deployment — replace them with your own before applying. See
  README.md's Quickstart step 1 for the full list.

## This deployment's specifics (Jacob's homelab — not applicable to other forks)

- This is a learning cluster, separate from the production `flux`-managed
  k3s "Dev Server" (10.1.0.34). Do not point this repo's automation at that
  cluster.
- Proxmox host: `prox.mox` / 10.1.0.99 (PVE 9.1.6, 256 threads, 125GB RAM).
  Existing VMs on it: 101 (pihole), 102 (dev/k3s), 103 (truenas) — never
  target those VMIDs from this repo's Terraform.
- VM disks and the Packer template live on the `nvme` storage pool (fast,
  matches the existing 3 VMs), not the larger `storage` zfspool.
- Network: single VLAN-aware bridge `vmbr0` (`bridge-vids 2-100`). This
  cluster's VMs live on VLAN 30 (`k8s-lab`), added via `UnifiTerraform`.
  No new Proxmox bridge is needed — just set the VLAN tag per VM.
- The 3 existing VMs use a firewall hookscript (`fix-fw-bridge.pl`) to fix
  fwpr-bridge attachment when per-VM firewall is enabled. This repo's VMs
  do NOT set `firewall = true` on their network device, so they never hit
  that bug and don't need the hookscript — which is just as well, since
  Proxmox only allows `root@pam` to set `hookscript` (an API token, even
  with VMAdmin ACLs, gets HTTP 500 "only root can set 'hookscript' config").
- **This repo is now GitOps-managed via Flux**, bootstrapped against this
  cluster (kubectl context `k8s-homelab`) into `clusters/k8s-homelab/`,
  synced from `github.com/JacobBanghart/k8s-homelab`.
- `clusters/k8s-homelab/flux-apps/` is a second Flux source pointed at
  `github.com/JacobBanghart/flux` — a separate, private repo of Jacob's
  personal app workloads. **This repo/URL is not accessible to anyone
  else** — if you're working in a fork, delete `flux-apps/` or repoint it
  at your own second source; don't try to make it reconcile as-is.
  Ongoing addon conventions (per-app dir, `nfs-rwx` StorageClass via NFS
  CSI against `truenas.home`, mandatory resource limits, secrets never in
  git) mirror that private repo's `AGENTS.md` — restated in generic form
  above for anyone without access to it.
