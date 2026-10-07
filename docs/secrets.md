# Secrets checklist

Nothing in this repo holds a secret, committed or not. Credentials live in
Vault (`VAULT_ADDR` is set in `mise.toml`), and each `mise run` task fetches
the ones it needs at run time, uncached — there are no `.tfvars` or
`.pkrvars.hcl` files to fill in. Log in first:

```
vault login -method=oidc role=admin
```

This doc is the single place listing what you need to gather, and in what
order, to stand this cluster up from nothing. Work through it top to bottom;
each phase's secrets are needed before that phase's tool runs. Field names
in Vault are the Terraform variable names (see `scripts/vault-tfvars`).

| Vault path | Fields | Used by |
|---|---|---|
| `secret/k8s-homelab/proxmox` | `proxmox_api_token` | `mise run tf`, `mise run packer` |
| `secret/unifi-terraform/controller` | `unifi_api_key`, `unifi_api_url`, `site` | `mise run tf:unifi` (shared with `UnifiTerraform`) |
| `secret/unifi-terraform/pihole` | `pihole_password` | `mise run tf:unifi` (shared with `UnifiTerraform`) |

The AWS stacks (`mise run tf:aws-backup`, `mise run tf:aws-kms`) and every
S3 state backend use your `~/.aws` credentials.

## 1. Packer (golden image)

`mise run packer` takes the same Proxmox token as Terraform (step 3) and
splits it into Packer's `proxmox_api_token_id` / `proxmox_api_token_secret`.
To create the token: Proxmox web UI -> Datacenter -> Permissions -> API
Tokens -> add a token for a user with VM/template management rights (e.g.
`terraform@pve!k8s-homelab`).

`ssh_public_key` comes from `TF_VAR_ssh_public_key` in `mise.toml`'s
`[env]` (it's public) — see "SSH keypair" below.

## 2. SSH keypair (used by Packer, Terraform, and Ansible)

Not stored in the repo at all — lives in your own `~/.ssh/`, referenced by
path (`ansible/ansible.cfg`'s `private_key_file`, `packer/variables.pkr.hcl`'s
`ssh_private_key_file`, both default to `~/.ssh/id_ed25519_k8s_homelab`).

Generate one if you don't already have it:
```
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_k8s_homelab -C k8s-homelab-ansible
```
The public key (`.pub`) is what goes into `TF_VAR_ssh_public_key` in
`mise.toml`, which both Packer and Terraform read.

## 3. Terraform (VM provisioning)

Vault: `secret/k8s-homelab/proxmox`, read by `mise run tf`.

| Field | What it is | How to get it |
|---|---|---|
| `proxmox_api_token` | Full Proxmox API token, `user@realm!tokenid=secret` format | The token from step 1 — combine the token ID and secret into one string |

```
vault kv put secret/k8s-homelab/proxmox proxmox_api_token=-   # paste, then Ctrl-D
```

## 4. Ansible

No secrets file needed. `ansible/ansible.cfg` points at the SSH key from
step 2. `ansible/.join-commands.sh` is generated automatically by the
`kubeadm_init` role on first run (it shells out to `kubeadm token create`)
and consumed by the `join_masters`/`join_workers` roles later in the same
playbook run — it's gitignored and ephemeral, nothing to prepare ahead of
time.

## 5. UniFi / Pi-hole (network config)

Vault: `secret/unifi-terraform/controller` and `secret/unifi-terraform/pihole`,
read by `mise run tf:unifi`. They belong to the `UnifiTerraform` repo, which
manages the rest of the same UniFi site with the same credentials.

| Field | What it is | How to get it |
|---|---|---|
| `unifi_api_key` | UniFi controller API key | UDM Pro UI -> Settings -> Admins & Users -> your user -> API Key |
| `unifi_api_url` | UniFi controller URL | Usually `https://<gateway-ip>` |
| `site` | UniFi site name | `default` unless you've renamed it |
| `pihole_password` | Pi-hole admin password | Whatever you set when Pi-hole was installed |

`pihole_url` defaults to `https://pi.hole` (`unifi/variables.tf`); add a
`pihole_url` field to the `pihole` secret to override it.

```
vault kv put secret/unifi-terraform/controller unifi_api_key=- unifi_api_url=https://<gateway-ip> site=default
vault kv put secret/unifi-terraform/pihole pihole_password=-
```

This directory only manages the k8s-lab VLAN and its firewall isolation —
it is not a copy of an entire home network's UniFi config. If you're
adapting this for your own network, treat `unifi/` as a reference for the
k8s-lab-specific resources (network + firewall zone/policy) to add to
your own UniFi Terraform setup, not a drop-in replacement for it.

## 6. In-cluster Kubernetes Secrets

Flux does not create these — they must exist in the cluster *before* the
relevant HelmRelease reconciles, or that release will sit in a
"secret not found" error state.

### Grafana admin credentials

Referenced by `clusters/k8s-homelab/monitoring/release.yaml` via
`grafana.admin.existingSecret: grafana-admin-credentials`. Create it once,
manually, after the `monitoring` namespace exists:

```
kubectl create secret generic grafana-admin-credentials \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
```

Retrieve the password later with:
```
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

### cert-manager CA / wildcard TLS cert

`clusters/k8s-homelab-config/cert-manager/ca.yaml` and `wildcard-cert.yaml`
create their own Secrets (`k8s-homelab-ca-secret`, `k8s-homelab-wildcard-tls`)
via cert-manager `Certificate` resources — nothing to create by hand here,
cert-manager generates and rotates these itself once its `ClusterIssuer` is
in place.

## Final check

A quick sweep for anything that might have slipped past this list:
```
git ls-files | xargs grep -liE 'password|secret|token|api[_-]?key' 2>/dev/null
```
Every hit should be a variable name, a comment, or a reference to *how* to
get a credential — never a live value. If you ever see a real-looking
token/password in that output, treat it as compromised and rotate it.
