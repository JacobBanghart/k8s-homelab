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
    k8s_homelab_vault    = { domain = "vault.k8s-homelab.local", ip = "10.4.0.200" }

    # Real Cloudflare-issued certs now (see traefik/release.yaml) --
    # temporary domain until each app migrates to its real final
    # hostname. Old .local records above left in place, not cleaned up.
    k8s_homelab_grafana_real  = { domain = "grafana.k8s-homelab.jacobbanghart.com", ip = "10.4.0.200" }
    k8s_homelab_vault_real    = { domain = "vault.k8s-homelab.jacobbanghart.com", ip = "10.4.0.200" }

    # headlamp migrated in from dev as an infra/platform tool (Wave 0 of
    # the dev-cluster migration) -- real hostname from the start, no
    # .local placeholder needed since this app never had one on dev.
    k8s_homelab_headlamp = { domain = "headlamp.k8s-homelab.jacobbanghart.com", ip = "10.4.0.200" }
  }
}

resource "pihole_dns_record" "local" {
  for_each = local.dns_records

  domain = each.value.domain
  ip     = each.value.ip
}
