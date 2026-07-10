# k8s-lab VLAN firewall isolation
#
# The rest of the home network's firewall rules (IoT/Friend legacy LAN_IN
# rules, primary VLAN protection) live in the UnifiTerraform repo's own
# firewall.tf with its own Terraform state -- this repo only manages
# k8s-lab's isolation. See README.md for why the split.

# =============================================================================
# k8s-lab VLAN Isolation - zone-based firewall policy (2026-07-09)
# =============================================================================
# The legacy unifi_firewall_rule resources this VLAN used to have (LAN_IN
# ruleset) are dead on a Zone-Based-Firewall controller -- this UDM Pro
# migrated to zone-based firewall, which replaced the legacy rule engine
# entirely. The old block_k8s_lab_to_{primary,friend,iot} rules previously
# showed `enabled: true` via the API but were never actually enforced.
#
# First attempt at this (an explicit zone + an explicit BLOCK policy on top
# of an explicit ALLOW) caused a real, brief outage -- see docs/decisions.md
# for the full incident writeup. Root cause, found reviewing the live
# policy set afterward: the BLOCK policy's connection_state_type defaulted
# to ALL, matching unconditionally regardless of connection state --
# including the *return* traffic (response packets, TCP ACKs, ping replies)
# for connections Internal itself initiated into k8s-lab. An unscoped
# "block everything from k8s-lab to Internal" also breaks the "Internal can
# reach k8s-lab" direction that's supposed to stay open, since nearly all
# two-way communication needs that return leg.
#
# Simpler, correct design (no explicit BLOCK policy needed at all): a new
# custom zone default-denies any zone-pair with no explicit policy (unlike
# the built-in zones, which ship with a predefined "Allow All Traffic"
# policy already). So creating the k8s-lab zone and adding *only* an
# Internal -> k8s-lab ALLOW (with its auto-generated RESPOND_ONLY return
# policy for established/related traffic) already leaves k8s-lab -> Internal
# for *new* connections with no explicit policy at all, which defaults to
# deny -- exactly the one-way isolation this needs, without ever touching
# the connection_state_type/connection_states fields (which are read-only/
# computed in the installed provider version 0.54.1 and can't be set via
# Terraform anyway).

data "unifi_firewall_zone" "internal" {
  name = "Internal"
}

resource "unifi_firewall_zone" "k8s_lab" {
  name        = "k8s-lab"
  network_ids = [unifi_network.k8s_lab.id]
}

resource "unifi_firewall_policy" "allow_internal_to_k8s_lab" {
  name                 = "Allow Internal to k8s-lab"
  action               = "ALLOW"
  protocol             = "all"
  create_allow_respond = true
  description          = "Management access (kubectl, SSH) from Internal into k8s-lab. k8s-lab initiating new connections back to Internal has no explicit policy and defaults to deny."

  source = {
    zone_id         = data.unifi_firewall_zone.internal.id
    matching_target = "ANY"
  }

  destination = {
    zone_id         = unifi_firewall_zone.k8s_lab.id
    matching_target = "ANY"
  }
}

