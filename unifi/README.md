# UniFi Network Terraform (k8s-lab only)

Infrastructure-as-code for just the `k8s-lab` VLAN and its firewall
isolation on the home UniFi Dream Machine Pro. Lives inside `k8s-homelab`
because it's the network this cluster runs on -- this directory manages
that one VLAN, `../terraform/` manages the VMs on it.

**The rest of the home network** (primary VLAN, other VLANs, WiFi, DHCP
reservations, port forwards, most Pi-hole DNS records) is managed by a
separate repo, `UnifiTerraform`, with its own independent Terraform state.
This directory intentionally does **not** duplicate that config -- one
UniFi site's resources are split by concern across two states, each
applied independently. Don't copy the other repo's resources back in here;
if you need to change something outside the `k8s-lab` VLAN, that's
`UnifiTerraform`'s job.

## Structure

```
.
├── main.tf              # Provider and backend config
├── variables.tf         # Input variables
├── vlans.tf             # k8s-lab VLAN/network definition
├── firewall.tf          # k8s-lab zone-based firewall policy
├── pihole_dns.tf        # Pi-hole DNS records for cluster apps (Grafana, demo-app)
└── outputs.tf           # Output values
```

## Network

| VLAN ID | Name | Subnet | Purpose |
|---------|------|--------|---------|
| 30 | k8s-lab | 10.4.0.0/24 | k8s-homelab cluster (isolated egress-only, see `../docs/decisions.md`) |

If you're standing this cluster up on your own UniFi controller: create a
VLAN like the one in `vlans.tf`, adjust the subnet/DHCP range to fit your
network, and use `firewall.tf`'s zone + policy as the template for keeping
it isolated from the rest of your LAN. See `../docs/new-environment-setup.md`
for the full portability checklist (what to customize vs. what's generic).

## Setup

### 1. Tools

`mise install` (from the repo root) installs the pinned Terraform, Vault CLI
and jq.

### 2. Credentials

The UniFi and Pi-hole credentials live in Vault, shared with
`UnifiTerraform`: `secret/unifi-terraform/controller` and
`secret/unifi-terraform/pihole`. `mise run tf:unifi` (from the repo root)
fetches them at run time. See `../docs/secrets.md` for where each value
comes from.

### 3. Initialize and apply

```bash
vault login -method=oidc role=admin
mise run tf:unifi -- init
mise run tf:unifi -- plan
mise run tf:unifi -- apply
```

If you already have a VLAN you want Terraform to adopt instead of create,
import it first:

```bash
mise run tf:unifi -- import unifi_network.k8s_lab <network-id>
```

## Security Notes

- Credentials are never written to disk: they come from Vault per run
- `terraform.tfstate` is gitignored and contains sensitive data
- Keep these files secure and backed up separately
