# =============================================================================
# Pi-hole Local DNS Records - k8s-homelab cluster apps only
#
# The rest of the home network's Pi-hole records (dev server, TrueNAS,
# Proxmox, the example.com hairpin) live in the UnifiTerraform repo's
# own pihole_dns.tf with its own Terraform state. See README.md.
# =============================================================================

locals {
  dns_records = {
    # All behind Traefik on the MetalLB VIP (10.4.0.200). Add a new entry
    # here per app -- Traefik's IngressRoute/Ingress host rule does the
    # actual routing once traffic arrives.
    k8s_homelab_grafana  = { domain = "grafana.k8s-homelab.local", ip = "10.4.0.200" }
    k8s_homelab_demo_app = { domain = "demo-app.k8s-homelab.local", ip = "10.4.0.200" }
    k8s_homelab_vault    = { domain = "vault.k8s-homelab.local", ip = "10.4.0.200" }
  }
}

resource "pihole_dns_record" "local" {
  for_each = local.dns_records

  domain = each.value.domain
  ip     = each.value.ip
}
