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
├── terraform.tfvars     # Your credentials (gitignored)
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

### 1. Install Terraform

```bash
# macOS
brew install terraform

# Linux
sudo apt install terraform
# or download from https://terraform.io/downloads
```

### 2. Configure Credentials

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your UniFi + Pi-hole credentials
```

See `../docs/secrets.md` for where each value comes from.

### 3. Initialize and apply

```bash
terraform init
terraform plan
terraform apply
```

If you already have a VLAN you want Terraform to adopt instead of create,
import it first:

```bash
terraform import unifi_network.k8s_lab <network-id>
```

## Security Notes

- `terraform.tfvars` is gitignored and contains credentials
- `terraform.tfstate` is gitignored and contains sensitive data
- Keep these files secure and backed up separately
