# Architecture

## Overview

```
Packer (packer/)          Terraform (terraform/)         Ansible (ansible/)
------------------         ----------------------         ------------------
Ubuntu 22.04 ISO      -->  clone template 9000       -->  common
+ containerd               into 3 masters + 3 workers      containerd
+ kubeadm/kubelet/kubectl  on VLAN 30 (k8s-lab),           kubeadm-init (master-0)
  (pinned)                 nvme storage, cloud-init        cni (Cilium)
= template VMID 9000       static IP/hostname/SSH key      join-masters (x2)
                                                            join-workers (x3)
```

## Proxmox layout

- Host: `prox.mox` (10.1.0.99), PVE 9.1.6, 256 threads / 125GB RAM.
- Existing VMs (do not touch from this repo): 101 (pihole), 102 (dev/k3s,
  managed by `flux/`), 103 (truenas).
- This project's VMs: template 9000 (`k8s-golden`), masters 9101-9103,
  workers 9111-9113.
- Storage: `nvme` pool (fast, same as existing VMs).
- Network: VLAN 30 (`k8s-lab`, 10.4.0.0/24), added via `UnifiTerraform`,
  fully isolated from the primary/friend/iot VLANs.

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
