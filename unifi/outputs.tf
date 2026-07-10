# =============================================================================
# Outputs
# =============================================================================

output "network" {
  description = "k8s-lab network/VLAN information"
  value = {
    id     = unifi_network.k8s_lab.id
    name   = unifi_network.k8s_lab.name
    subnet = unifi_network.k8s_lab.subnet
    vlan   = unifi_network.k8s_lab.vlan
  }
}
