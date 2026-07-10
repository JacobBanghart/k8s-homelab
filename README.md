# k8s-homelab

A repeatable, "low-budget EKS at home" — a 3-master/3-worker vanilla kubeadm
Kubernetes cluster on Proxmox VMs, provisioned end-to-end from scratch:

1. **Packer** bakes a golden VM image (Ubuntu 22.04 + containerd + pinned
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

This cluster is separate from the existing single-node k3s "Dev Server"
(10.1.0.34, managed via the separate GitLab-hosted `flux/` repo) — it
exists to practice real multi-node kubeadm/etcd/CNI operations and to be
a template for eventually spanning multiple physical hosts.

See `docs/architecture.md`, `docs/runbook.md`, and `docs/decisions.md` for
details.

## Layout

```
packer/      golden VM image definition
terraform/   VM provisioning (clones of the Packer template)
ansible/     OS config + kubeadm cluster bootstrap
clusters/    Flux GitOps config for this cluster (kubectl context k8s-homelab)
docs/        architecture notes, operational runbook, decision log
```

## Prerequisites

- `packer`, `terraform`, `ansible` installed locally
- SSH access to the Proxmox host (`prox.mox`, 10.1.0.99)
- A Proxmox API token with permissions to manage VMs (for Terraform)
