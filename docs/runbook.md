# Runbook

## First-time setup

```bash
# 1. Packer: build the golden template (VMID 9000)
cd packer
cp k8s-node.auto.pkrvars.hcl.example k8s-node.auto.pkrvars.hcl   # fill in real values
packer init .
packer validate .
packer build .

# 2. Terraform: clone masters + workers
cd ../terraform
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform plan
terraform apply

# 3. Ansible: bootstrap the cluster
cd ../ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping                       # connectivity check
ansible-playbook playbook.yml --check     # dry run
ansible-playbook playbook.yml             # full bootstrap
```

## Re-running a single stage

Every Ansible stage is idempotent and independently re-runnable:

```bash
ansible-playbook playbook.yml --tags common
ansible-playbook playbook.yml --tags containerd
ansible-playbook playbook.yml --tags kubeadm-init
ansible-playbook playbook.yml --tags cni
ansible-playbook playbook.yml --tags join-masters
ansible-playbook playbook.yml --tags join-workers
ansible-playbook playbook.yml --tags metrics-server
```

## Verifying the cluster

```bash
export KUBECONFIG=... # copied from /home/ansible/.kube/config on k8s-master-0
kubectl get nodes -o wide          # all 6 Ready
kubectl get pods -A                # cilium/coredns Running
kubeadm certs check-expiration     # run on any master
kubectl create deployment nginx-test --image=nginx --replicas=3
kubectl expose deployment nginx-test --port=80
kubectl get pods -o wide           # confirm spread across workers
```

## Adding this cluster as a kubectl context on your workstation

Merge it in as a new named context rather than overwriting your existing
kubeconfig (e.g. the dev/k3s "default" context):

```bash
ssh -i ~/.ssh/id_ed25519_k8s_homelab ansible@10.4.0.10 'sudo cat /etc/kubernetes/admin.conf' > /tmp/k8s-homelab-admin.conf
kubectl config rename-context kubernetes-admin@kubernetes k8s-homelab --kubeconfig /tmp/k8s-homelab-admin.conf
# optionally also rename the cluster/user entries inside the file to
# `k8s-homelab` / `k8s-homelab-admin` to avoid future name collisions
cp ~/.kube/config ~/.kube/config.bak
KUBECONFIG=~/.kube/config:/tmp/k8s-homelab-admin.conf kubectl config view --flatten > /tmp/merged.yaml
cp /tmp/merged.yaml ~/.kube/config
kubectl --context k8s-homelab get nodes
```

## Idempotency check

```bash
terraform plan            # should show no changes after a clean apply
ansible-playbook playbook.yml --check --diff
```

## Tearing down

```bash
cd terraform
terraform destroy         # removes the 6 cluster VMs (not the template)
```

To remove the golden template too: `qm destroy 9000` on the Proxmox host.

## Backup / restore (vzdump)

VMs are backed up nightly at 03:00 to a TrueNAS NFS export (Proxmox storage
`truenas-vzdump`), scheduled via `pvesh create /cluster/backup` (see
`docs/decisions.md` for the full setup). This is intentionally *not*
Terraform-managed (it's a host-level Proxmox job, not a Terraform resource).

### Restore drill (verify a backup is actually usable)

Don't trust a backup until you've restored it. Restore to a **scratch VMID**
with networking disabled, never restore over a live node in place unless
you're actually doing a real recovery:

```bash
# on the Proxmox host
ls /mnt/pve/truenas-vzdump/dump/                      # find the archive
qmrestore /mnt/pve/truenas-vzdump/dump/<archive>.vma.zst 9999 --storage nvme

# disable networking before first boot -- the restored VM has the same
# static IP/MAC as the live node it was backed up from, and booting it
# on the same VLAN with networking live will conflict
qm set 9999 --net0 virtio=<mac-from-qm-config>,bridge=vmbr0,tag=<vlan>,link_down=1 \
            --name scratch-restore-test

qm start 9999
qm agent 9999 ping                    # blocks/retries until qemu-guest-agent
                                       # responds -- proves kernel+rootfs+
                                       # cloud-init all came up cleanly,
                                       # works even with networking down
                                       # since it's virtio-serial, not IP
qm guest exec 9999 -- hostname        # sanity check real command execution
qm guest exec 9999 -- cat /etc/kubernetes/manifests/etcd.yaml   # spot-check
                                                                  # real file
                                                                  # content

# clean up
qm stop 9999
qm destroy 9999
```

Last verified: 2026-07-09, restored the master-0 (VMID 9101) backup from
that same day -- booted cleanly, guest agent responded, and the restored
`etcd.yaml` manifest content matched the real live master-0 configuration
at backup time.

### Actual disaster recovery (restoring over/replacing a real node)

Not yet drilled end-to-end (e.g. rejoining a restored master into the live
etcd cluster, or restoring a worker and having it reappear correctly in
the cluster). If you ever need to do this for real: stop the broken VM
first, `qmrestore ... <same-vmid>` to overwrite it in place (or restore to
a new VMID and swap it in), and expect to deal with stale node identity
in the kubeadm/etcd membership list depending on how long the node was
down. Treat this as a real incident, not a routine procedure, until it's
been tested properly.

## OS patching and cluster upgrades

Security-only OS patches apply automatically (`unattended-upgrades`,
`ansible/roles/unattended_upgrades/`, tag `unattended-upgrades`) -- origins
restricted to `<codename>-security` (not `-updates`), `kubeadm`/`kubectl`/
`kubelet` held so a routine patch run can never silently bump the cluster's
Kubernetes version, and automatic reboot explicitly disabled. Two things
this does *not* cover, which need a manual procedure:

### Kernel / reboot-requiring updates

`unattended-upgrades` installs the packages but never reboots automatically
(by design -- see above). Check for a pending reboot and handle nodes one
at a time:

```bash
# on each node
[ -f /var/run/reboot-required ] && echo "reboot needed"
```

```bash
# from your workstation, one node at a time -- never drain/reboot more
# than one node (and never more than one master) simultaneously
kubectl --context k8s-homelab cordon k8s-worker-0
kubectl --context k8s-homelab drain k8s-worker-0 --ignore-daemonsets --delete-emptydir-data
ssh -i ~/.ssh/id_ed25519_k8s_homelab ansible@10.4.0.20 sudo reboot
# wait for it to come back:
kubectl --context k8s-homelab wait --for=condition=Ready node/k8s-worker-0 --timeout=300s
kubectl --context k8s-homelab uncordon k8s-worker-0
# confirm cluster health before moving to the next node
kubectl --context k8s-homelab get nodes
```

For a master, additionally confirm etcd is healthy again before moving on
(same reasoning as the control-plane-metrics rollout in
`ansible/roles/control_plane_metrics/`):

```bash
kubectl --context k8s-homelab exec -n rook-ceph deploy/rook-ceph-tools -- \
  etcdctl --endpoints=https://10.4.0.10:2379,https://10.4.0.11:2379,https://10.4.0.12:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health
# (or just: kubectl get pods -n kube-system -l component=etcd)
```

### Kubernetes version upgrades

Not automated -- `kubeadm`/`kubectl`/`kubelet` are held specifically so this
only happens deliberately. Standard `kubeadm` upgrade sequence, one master
at a time, workers last, each node drained first:

```bash
# 1. First master: check the upgrade plan
ssh -i ~/.ssh/id_ed25519_k8s_homelab ansible@10.4.0.10
sudo apt-mark unhold kubeadm && sudo apt-get update && sudo apt-get install -y kubeadm=<version>
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v<version>

# unhold and upgrade kubelet/kubectl on this node, then restart kubelet
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=<version> kubectl=<version>
sudo apt-mark hold kubeadm kubelet kubectl
sudo systemctl restart kubelet

# 2. Remaining masters (one at a time, drain first)
kubectl --context k8s-homelab cordon k8s-master-1
kubectl --context k8s-homelab drain k8s-master-1 --ignore-daemonsets --delete-emptydir-data
ssh -i ~/.ssh/id_ed25519_k8s_homelab ansible@10.4.0.11
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=<version>
sudo kubeadm upgrade node
sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y kubelet=<version> kubectl=<version>
sudo apt-mark hold kubeadm kubelet kubectl
sudo systemctl restart kubelet
kubectl --context k8s-homelab uncordon k8s-master-1
# repeat for k8s-master-2

# 3. Workers last, same drain -> upgrade -> uncordon pattern, but
# `kubeadm upgrade node` only (no `upgrade apply`/`upgrade plan`, those
# are control-plane-only)
```

Not yet exercised end-to-end on this cluster -- treat the first real
version bump as a drill, not a routine operation, and verify cluster
health (`kubectl get nodes`, a real workload still schedules/serves
traffic) after each node before moving to the next.

## Vault

Deployed via `clusters/k8s-homelab/vault/` -- HA, 3-replica Raft storage,
AWS KMS auto-unseal (key provisioned in `terraform-aws-kms/`), internal
TLS from `k8s-homelab-ca-issuer`. Externally reachable at
`vault.k8s-homelab.jacobbanghart.com` via Traefik TLS bridging (real
Let's Encrypt cert on the client-facing leg, re-encrypted to Vault's
internal cert on the backend leg -- see `vault/serverstransport.yaml`).
In-cluster consumers (ESO) talk to `vault.vault.svc.cluster.local`
directly and never touch this external hostname. See
`docs/decisions.md`.

### One-time init (already done for this cluster's current install)

```bash
kubectl --context k8s-homelab -n vault exec vault-0 -- sh -c \
  'VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt \
   vault operator init -recovery-shares=5 -recovery-threshold=3'
```

With AWS KMS auto-unseal, this immediately unseals all 3 pods -- no
`vault operator unseal` step. Save the 5 recovery key shares + initial
root token somewhere that survives this cluster (and, ideally, this
whole home network) being down -- they're break-glass credentials for
`rekey`/`generate-root`, not needed for routine operation, but that also
means they're exactly the kind of secret you'd reach for during a real
outage. **Do not store them anywhere that depends on this cluster or
`dev` being up** (i.e. not in a self-hosted Vaultwarden instance running
on either) -- see the note in `docs/decisions.md`.

### Restarting a pod / picking up a config change

The Helm chart uses `OnDelete` update strategy deliberately (Vault's own
guidance -- avoid an uncontrolled automatic rolling restart of a quorum
store). After any change that touches the StatefulSet template, restart
pods one at a time, **standbys before the active node**, waiting for each
to report ready before moving on:

```bash
kubectl --context k8s-homelab -n vault get pods   # note which is active (HA Mode)
kubectl --context k8s-homelab -n vault delete pod vault-1   # a standby first
# wait for 1/1 Ready, then repeat for the other standby, active node last
```

### Checking status

```bash
kubectl --context k8s-homelab -n vault exec vault-0 -- sh -c \
  'VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status'
# Sealed: false, Seal Type: awskms -- confirms auto-unseal is actually
# active and this hasn't silently fallen back to Shamir.
```

### External Secrets Operator (consumer wiring)

Deployed via `clusters/k8s-homelab/external-secrets/` +
`clusters/k8s-homelab-config/external-secrets/` (same CRD
chicken-and-egg split as cert-manager/metallb -- the `ClusterSecretStore`
can't apply until ESO's CRDs exist). Uses Vault's native Kubernetes auth
method (`auth/kubernetes/`) against k8s-homelab's own API -- no AppRole
role-id/secret-id bootstrap needed, since Vault and its consumers share
a cluster. `vault-server-binding` (created by the Vault Helm chart)
already grants Vault's own ServiceAccount `system:auth-delegator`, which
is what lets it call the TokenReview API to validate ESO's SA token.

One-time Vault-side setup (already done for this cluster's current
install -- re-run only after a full Vault reinit, e.g. following a
break-glass credential loss):

```bash
VAULT_TOKEN=<root-token>
kubectl --context k8s-homelab -n vault exec vault-0 -- sh -c "
VAULT_SKIP_VERIFY=true VAULT_TOKEN=$VAULT_TOKEN vault secrets enable -path=secret -version=2 kv
VAULT_SKIP_VERIFY=true VAULT_TOKEN=$VAULT_TOKEN vault auth enable kubernetes
VAULT_SKIP_VERIFY=true VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/config \
  kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
"
```

Policy + role (read-only on the whole `secret/` KV mount -- narrow to
specific paths per-app once real secrets start landing here):

```bash
kubectl --context k8s-homelab -n vault exec vault-0 -- sh -c "
cat <<'POLICY' > /tmp/eso-policy.hcl
path \"secret/data/*\" { capabilities = [\"read\"] }
path \"secret/metadata/*\" { capabilities = [\"list\", \"read\"] }
POLICY
VAULT_SKIP_VERIFY=true VAULT_TOKEN=$VAULT_TOKEN vault policy write eso-reader /tmp/eso-policy.hcl
VAULT_SKIP_VERIFY=true VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-reader \
  ttl=1h
"
```

The `ClusterSecretStore` (`vault-backend`) trusts Vault's internal CA via
a `k8s-homelab-ca-cert` secret copied into the `external-secrets`
namespace (public cert only -- never copy the CA secret that holds the
private key). The source secret (in the `vault` namespace) stores the
cert under the key **`tls.ca`**, not `ca.crt` -- easy to get wrong by
copying the `vault/serverstransport.yaml` pattern verbatim, which uses
a different secret shape. Extract and recreate it as:

```bash
kubectl --context k8s-homelab -n vault get secret k8s-homelab-ca-cert \
  -o jsonpath='{.data.tls\.ca}' | base64 -d > /tmp/ca.crt
kubectl --context k8s-homelab -n external-secrets create secret generic \
  k8s-homelab-ca-cert --from-file=ca.crt=/tmp/ca.crt
rm /tmp/ca.crt
```

If you fix this secret after the ESO controller is already running,
`kubectl rollout restart deployment/external-secrets` -- its informer
cache won't pick up the change on its own, and it'll keep reporting the
same stale `InvalidProviderConfig` error otherwise.

Checking it's working:

```bash
kubectl --context k8s-homelab -n external-secrets get clustersecretstore vault-backend
# STATUS should show Valid; check `kubectl describe` if not.
```

### OIDC auth method (Authentik SSO)

Lets users log into Vault (UI and CLI) with their Authentik identity
instead of distributing the root token or per-user tokens by hand.
Authentik side: an OAuth2/OpenID Provider + Application named "Vault"
(created via Authentik's web UI — Authentik has no Terraform/declarative
config in this homelab, so the provider/application only exist in
Authentik's own database, not as code anywhere). Vault side: the
built-in `oidc` auth method, config below. See `docs/decisions.md` for
the two bugs hit standing this up (stale client credentials from
Authentik's wizard, missing `email`/`profile` scope).

One-time setup (already done for this cluster's current install —
re-run only after a full Vault reinit):

```bash
vault auth enable oidc

vault write auth/oidc/config \
  oidc_discovery_url="https://auth.jacobbanghart.com/application/o/vault/" \
  oidc_client_id="<from Authentik: Applications -> Vault -> provider edit page>" \
  oidc_client_secret="<same page — never commit this value>"

vault write auth/oidc/role/default \
  bound_audiences="<same client_id as above>" \
  allowed_redirect_uris="https://vault.k8s-homelab.jacobbanghart.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  user_claim="email" \
  oidc_scopes="email,profile" \
  policies="default" \
  ttl="1h"
```

`oidc_scopes` must explicitly list `email`/`profile` — Vault only
requests the bare `openid` scope by default, so without this the login
succeeds but Vault fails with `claim "email" not found in token` even
though Authentik's provider already has the email scope mapping
attached. The two `allowed_redirect_uris` cover the Vault UI's own
callback and the CLI's local callback (`vault login -method=oidc`
spins up `localhost:8250` to catch the browser redirect) — both are
needed, not just one or the other.

Client ID/secret are regenerated by Authentik's application wizard on
every form re-render, so don't copy them mid-wizard — save the
application first, then re-open the saved provider's edit page and
copy from there.

Logging in:

```bash
export VAULT_ADDR="https://vault.k8s-homelab.jacobbanghart.com"
vault login -method=oidc
```

`vault login -method=oidc` (no `role=`) grants only the built-in
`default` policy (minimal, no admin access).

### OIDC: per-identity admin role

A second role, `admin`, grants the `admin` ACL policy (`path "*" {
capabilities = ["create","read","update","delete","list","sudo"] }`,
already present as a standalone policy) but only to the specific
identity bound via `bound_claims` — everyone else authenticating
through Authentik still lands on the minimal `default` role.

```bash
vault write auth/oidc/role/admin \
  bound_audiences="<same client_id as auth/oidc/config>" \
  allowed_redirect_uris="https://vault.k8s-homelab.jacobbanghart.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  user_claim="email" \
  bound_claims='{"email":"jacobmbanghart@gmail.com"}' \
  oidc_scopes="email,profile" \
  policies="admin" \
  ttl="1h"
```

`bound_claims` is a map-type field, and passing it as an inline
`key='{"...":"..."}'` flag is fragile — zsh's bracket-matching can
silently mangle the braces/quotes mid-paste, producing a `400: error
converting input for field "bound_claims": '' expected a map, got
'string'` error with no indication the value itself was corrupted.
More reliable: write the whole role as a JSON file and pass it with
`@`, which sidesteps shell quoting entirely:

```bash
cat > /tmp/admin-role.json <<'EOF'
{
  "bound_audiences": "<client_id>",
  "allowed_redirect_uris": ["https://vault.k8s-homelab.jacobbanghart.com/ui/vault/auth/oidc/oidc/callback", "http://localhost:8250/oidc/callback"],
  "user_claim": "email",
  "bound_claims": {"email": "jacobmbanghart@gmail.com"},
  "oidc_scopes": ["email", "profile"],
  "policies": ["admin"],
  "ttl": "1h"
}
EOF
vault write auth/oidc/role/admin @/tmp/admin-role.json
rm /tmp/admin-role.json
```

Note: Vault's UI supports configuring the `oidc` auth method itself
(Access → Auth Methods → oidc → Configuration) but has no Roles tab for
`jwt`/`oidc` methods — unlike AppRole or Kubernetes auth, role
management here is CLI/API only.

Use it: `vault login -method=oidc role=admin`. If `VAULT_TOKEN` is
still exported in the shell from an earlier root-token session, it
takes precedence over the freshly stored login token — `unset
VAULT_TOKEN` after logging in to confirm you're actually running as
the OIDC identity (`vault token lookup` should show `display_name:
oidc-<email>`, not the root token).

## Grafana (monitoring stack)

Deployed as part of `clusters/k8s-homelab/monitoring/` (the
`kube-prometheus-stack` HelmRelease's bundled `grafana` subchart), at
`https://grafana.k8s-homelab.jacobbanghart.com`. Single replica on a
`ceph-block` (RWO) PVC -- deliberately RWO, not RWX/CephFS, since
there's only ever one writer and CephFS's multi-writer coordination
would be pure overhead here.

### OIDC auth method (Authentik SSO)

Same pattern as Vault's OIDC section above -- separate Authentik
OAuth2 Provider + Application named "Grafana" (web UI only, not
declarative). Config lives in `clusters/k8s-homelab/monitoring/release.yaml`
under `values.grafana`:

- `deploymentStrategy: {type: Recreate}` -- **required**, not optional
  polish. Chart default (`RollingUpdate`) deadlocks on *any* future
  change to this Deployment (single replica + RWO PVC -- new pod can't
  mount the volume while the old one holds it, old one won't terminate
  until the new one's ready). Key is `deploymentStrategy`, not
  `strategy` (a different, unrelated key elsewhere in this chart's
  values tree that silently no-ops if used here by mistake). See
  `docs/decisions.md` for the full incident and the one-time
  `kubectl patch` needed if a stuck rollout needs unblocking
  immediately rather than waiting out Helm's 5m timeout.
- `grafana.ini: server: root_url` -- must be set to the real public
  HTTPS hostname, or Grafana generates OAuth `redirect_uri`s from its
  own internal listener address and Authentik rejects them as a
  Redirect URI Error.
- `grafana.ini: auth.generic_oauth` -- `client_id` inline (not
  secret -- visible in any browser OAuth redirect anyway),
  `client_secret: $__env{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}` sourced
  via `envValueFrom` from the `grafana-oidc` Secret (ESO-synced from
  Vault `monitoring/grafana-oidc`, see
  `grafana-oidc-externalsecret.yaml`) -- never committed.
- `oidc_scopes`-equivalent here is just `scopes: "openid email profile"`
  directly in the ini, same reasoning as Vault: without `email`/`profile`
  explicitly listed, Authentik won't include those claims even with the
  scope mapping attached to the provider.

When copying the client_secret out of Authentik's masked field by
hand, double- and triple-check it -- a single misread character
(`0`/`O`, `l`/`L`) produces `oauth2: "invalid_client" "Client
authentication failed"` at Grafana's token-exchange step, which reads
like a generic config problem, not "one character wrong two-thirds of
the way through a 128-char string." See `docs/decisions.md` for a
technique to verify a live masked field's value against a guess
without ever exposing the full secret (binary-search prefix
comparison via browser JS, returning only booleans).

## demo-app (Homepage dashboard)

Deployed via `clusters/k8s-homelab/demo-app/` -- despite the namespace
name, this runs [Homepage](https://gethomepage.dev), not a demo. Reachable
at `https://demo-app.k8s-homelab.jacobbanghart.com` (no auth).

### Adding a new service tile

Edit `demo-app/release.yaml`'s `values.config.services` list:

```yaml
- Core Infrastructure:
    - Some New App:
        href: https://some-app.k8s-homelab.jacobbanghart.com
        description: One-line description
        icon: some-app.png   # see https://github.com/homarr-labs/dashboard-icons
```

Commit and push -- Homepage's ConfigMap is regenerated by the
HelmRelease and the pod picks it up without a manual restart. No
per-app annotation or RBAC change needed; tiles are declared centrally
here rather than via the `gethomepage.dev/enabled` Deployment-annotation
auto-discovery pattern (which would mean touching every other app's
manifests just to appear on the dashboard).

### Cluster stats widget

The `kubernetes` widget (cluster + per-node CPU/memory) needs its own
RBAC, granted via `enableRbac: true` / `serviceAccount.create: true` in
`release.yaml` -- read-only, scoped to whatever the chart's own
`ClusterRole` requests, unrelated to any other app's permissions.
