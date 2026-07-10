# =============================================================================
# VLAN / Network
# =============================================================================
# This repo's unifi/ only manages the k8s-lab VLAN and its firewall
# isolation -- the rest of the home network (primary/friend/iot VLANs,
# WiFi, DHCP reservations, port forwards) lives in a separate repo
# (UnifiTerraform) with its own Terraform state. See README.md for why.
#
# Provider schema note: written for ubiquiti-community/unifi v0.43.0+, which
# uses nested blocks (dhcp_server{}, dhcp_v6_server{}) and a subnet expressed
# as gateway-IP/prefix rather than network-address/prefix. See
# docs/decisions.md for the full migration writeup.

# k8s-lab Network (VLAN 30 - Isolated)
# Dedicated VLAN for the k8s-homelab kubeadm learning cluster, to keep its
# blast radius separate from the primary/dev-k3s/pihole/TrueNAS VLAN.
resource "unifi_network" "k8s_lab" {
  auto_scale = false
  lte_lan    = false
  name       = "k8s-lab"
  site       = var.site

  subnet = "10.4.0.1/24"
  vlan   = 30

  dhcp_server = {
    enabled           = true
    conflict_checking = false
    start             = "10.4.0.6"
    # Reserve 10.4.0.200-220 outside the DHCP range for MetalLB's static
    # LoadBalancer IP pool (see k8s-homelab/clusters/k8s-homelab/metallb/).
    stop = "10.4.0.199"
  }

  multicast_dns       = true
  ipv6_interface_type = "none"
  setting_preference  = "manual"
  # Live value is currently null (likely never set on creation); every other
  # network on this UniFi site already has "default" -- harmless, matching
  # field, no functional effect either way.
  gateway_type = "default"

  ipv6_ra_preferred_lifetime = "4h0m0s"
  ipv6_ra_valid_lifetime     = "24h0m0s"
}
