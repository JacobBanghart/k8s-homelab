# k8s-homelab

A repeatable, "low-budget EKS at home" — a 3-master/3-worker vanilla kubeadm
Kubernetes cluster on Proxmox VMs, provisioned end-to-end from scratch:

1. **Packer** bakes a golden VM image (Ubuntu 24.04 + containerd + pinned
   kubeadm/kubelet/kubectl + k8s sysctls/kernel modules) into a Proxmox
   template.
2. **Terraform** (`bpg/proxmox` provider) clones that template into 3
   control-plane and 3 worker VMs on a dedicated VLAN, with per-node
   cloud-init for static IPs/hostnames/SSH keys.
3. **Ansible** configures the OS and bootstraps the cluster in discrete,
   idempotent, tag-based stages (`common` -> `containerd` -> `kubeadm-init`
   -> `cni` -> `join-masters` -> `join-workers` -> `metrics-server`), so
   any stage can be re-run or resumed on its own.
4. **Flux** takes over from there for ongoing addons (storage, ingress,
   load balancing, etc.) — bootstrapped into `clusters/k8s-homelab/` in
   this same repo, synced from GitHub. New addons go in as Flux-managed
   app directories, not more Ansible roles.

This cluster was built to practice real multi-node kubeadm/etcd/CNI
operations, and to be a template someone else with a Proxmox box + UniFi
gateway could stand their own copy up from.

See `docs/architecture.md`, `docs/runbook.md`, and `docs/decisions.md` for
details, `docs/secrets.md` for every credential you'll need, and the
Quickstart below for the actual step-by-step build.

## Layout

```
packer/      golden VM image definition
terraform/   VM provisioning (clones of the Packer template)
ansible/     OS config + kubeadm cluster bootstrap
unifi/       UniFi VLAN + firewall isolation for the cluster's network
clusters/    Flux GitOps config for this cluster (kubectl context k8s-homelab)
docs/        architecture notes, operational runbook, decision log
```

## Prerequisites

- `packer`, `terraform`, `ansible`, `flux` (the CLI), and `kubectl` installed
  locally
- A Proxmox host, reachable over SSH and its API, with a storage pool for
  VM disks
- A UniFi gateway (or any router that can do VLANs/DHCP/firewall — `unifi/`
  is UniFi-specific, but the pattern — one VLAN, a firewall zone/policy
  isolating it — is not)
- A GitHub account, for Flux to sync this repo's `clusters/` directory
  into the running cluster

If you've never touched Packer or Ansible before: Packer's job here is
narrow — it boots an Ubuntu ISO in an automated (unattended) install,
runs a few shell scripts against it, and converts the result into a
Proxmox VM template, so Terraform can clone that template instead of
installing the OS from scratch on every VM. Ansible's job is to SSH into
already-running VMs and bring them from "freshly booted clone" to
"kubeadm cluster member" through a sequence of idempotent tagged plays —
idempotent meaning you can re-run any of them as many times as you want
and they'll only change what's actually out of date, which is what makes
the whole thing safe to resume after a partial failure.

## Quickstart

Gather every credential you'll need up front — see `docs/secrets.md` for
the full list and where each one comes from (Proxmox API token, SSH
keypair, UniFi API key, Pi-hole password). Do that first; every step
below assumes you already have them.

### 1. Adjust the config for your own environment

Nothing below is generic-by-default — it's this specific cluster's IPs,
node counts, and Proxmox object names. Before building anything, go
through:

- `packer/variables.pkr.hcl` — Proxmox node/storage pool names, template
  VMID, Ubuntu version.
- `terraform/variables.tf` — Proxmox connection info, VLAN tag, master/
  worker IPs and VM IDs (the `masters`/`workers` maps, each entry also
  carrying a `node` field for which physical Proxmox host to clone onto —
  see `docs/architecture.md` for multi-host setups), disk sizing.
- `ansible/inventory/hosts.ini` — must match whatever static IPs you put
  in `terraform/variables.tf`.
- `unifi/vlans.tf` and `unifi/firewall.tf` — the VLAN subnet/DHCP range
  and the isolation policy, if you're using UniFi too. If not, recreate
  the same idea (one VLAN, deny-by-default except explicit management
  access) in whatever your gateway uses.

### 2. Build the golden image (Packer)

```bash
cd packer
cp k8s-node.auto.pkrvars.hcl.example k8s-node.auto.pkrvars.hcl
# fill in proxmox_api_token_secret and ssh_public_key
packer init k8s-node.pkr.hcl
packer build k8s-node.pkr.hcl
```

This boots an Ubuntu ISO against Proxmox, unattended-installs it,
provisions containerd + kubeadm/kubelet/kubectl via the scripts in
`packer/scripts/`, then shuts it down and converts it into a VM template
(`template_vm_id` in `variables.pkr.hcl`, default `9000`). Takes roughly
10-15 minutes. Nothing after this step touches Packer again — Terraform
just clones the template it leaves behind.

### 3. Provision the VMs (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# fill in proxmox_api_token and ssh_public_key
terraform init
terraform plan
terraform apply
```

This clones the template into however many master/worker VMs you defined
in `variables.tf`, each with cloud-init setting its static IP, hostname,
and SSH key. Nothing is configured yet at this point — they're just
booted, reachable VMs.

### 4. Bootstrap the cluster (Ansible)

```bash
cd ansible
ansible-playbook playbook.yml
```

Runs every tagged stage in order end to end: OS baseline, containerd
drift-check, `kubeadm init` on the first master, Cilium (CNI), the other
two masters joining, all workers joining, then metrics-server. If it
fails partway through (a VM not up yet, a typo in the inventory), fix the
problem and re-run the same command — every stage is safe to repeat. To
run a single stage on its own instead of the whole playbook:

```bash
ansible-playbook playbook.yml --tags kubeadm-init
```

At the end of this step you have a real, working 3-master/3-worker
cluster with no storage, ingress, or observability yet — those come from
Flux next.

### 5. Point kubectl at it

```bash
scp ansible@<master-0-ip>:/etc/kubernetes/admin.conf ~/.kube/k8s-homelab.conf
export KUBECONFIG=~/.kube/k8s-homelab.conf:~/.kube/config
kubectl config rename-context kubernetes-admin@kubernetes k8s-homelab
kubectl --context k8s-homelab get nodes
```

### 6. Bootstrap Flux and let it apply everything else

```bash
export GITHUB_TOKEN=<a token with repo scope>
flux bootstrap github \
  --owner=<your-github-username> \
  --repository=<your-fork-of-this-repo> \
  --branch=main \
  --path=clusters/k8s-homelab \
  --personal \
  --context=k8s-homelab
```

This installs the Flux controllers into the cluster and points them at
`clusters/k8s-homelab/` in your own fork of this repo. From here, Rook/
Ceph, MetalLB, Traefik, cert-manager, and the monitoring stack all
reconcile in automatically — nothing further to run by hand. A couple of
those addons need a Kubernetes Secret to exist before they'll come up
cleanly (Grafana's admin credentials, most notably) — see
`docs/secrets.md` section 6 for the exact command.

Give it a few minutes, then check everything came up:

```bash
kubectl --context k8s-homelab get helmreleases -A
kubectl --context k8s-homelab get kustomizations -A
```

Both should show `READY: True` across the board once Flux has finished
reconciling.
