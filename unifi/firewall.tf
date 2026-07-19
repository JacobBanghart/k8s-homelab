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

# =============================================================================
# k8s-lab -> TrueNAS (NFS, port 2049 only) -- added for the dev-cluster
# migration (2026-07-19)
# =============================================================================
# k8s-lab has no other explicit outbound policy (see the design note
# above), so without this, migration jobs mounting TrueNAS NFS to copy app
# data across just hang on the mount (silent default-deny, no rejection).
# Scoped to TrueNAS's single IP and NFSv4's single consolidated port
# (2049 -- portmapper/111 isn't needed since migration jobs mount
# explicitly as nfs4, not nfs3) rather than the whole Internal zone, to
# keep this as narrow as the isolation this VLAN was built for allows.
# Given the prior outage from an under-scoped k8s-lab firewall change (see
# the design note above and docs/decisions.md), double-check this in a
# `terraform plan` before applying, same as always, but especially here.
resource "unifi_firewall_policy" "allow_k8s_lab_to_truenas_nfs" {
  name                 = "Allow k8s-lab to TrueNAS (NFS)"
  action               = "ALLOW"
  protocol             = "tcp"
  create_allow_respond = true
  description          = "NFS data migration jobs (k8s-lab -> TrueNAS) during the dev-cluster migration. Scoped to TrueNAS's IP and NFSv4's port only."

  source = {
    zone_id         = unifi_firewall_zone.k8s_lab.id
    matching_target = "ANY"
  }

  destination = {
    zone_id            = data.unifi_firewall_zone.internal.id
    matching_target    = "IP"
    ips                = ["10.1.0.45/32"]
    port_matching_type = "SPECIFIC"
    port               = "2049"
  }
}

# =============================================================================
# k8s-lab -> iot subnet (all ports/protocols) -- Home Assistant control
# =============================================================================
# home-assistant migrated into k8s-lab (see docs/decisions.md's mDNS entry),
# but k8s-lab -> Internal defaults to deny for new connections (by design,
# see the top of this file), same as it did for the NFS case above. Without
# this, HA can discover devices (mDNS reflection is handled separately, at
# the gateway) but can't actually poll/control them -- ESPHome's native API
# (6053) and other IoT integrations use a mix of ports, so this is scoped
# to the whole iot subnet rather than enumerating each one.
#
# `iot` itself has no dedicated firewall zone -- it's never been split out
# of the default Internal zone, so `iot` already has broad access back into
# k8s-lab via the existing Internal -> k8s-lab policy above (more open than
# ideal, but pre-existing and out of scope here; see UnifiTerraform's
# firewall.tf for the fuller note on iot/friend's vestigial isolation).
# This policy only opens the other direction, narrowly, to unblock HA.
resource "unifi_firewall_policy" "allow_k8s_lab_to_iot" {
  name                 = "Allow k8s-lab to iot"
  action               = "ALLOW"
  protocol             = "all"
  create_allow_respond = true
  description          = "Home Assistant (k8s-lab) controlling IoT devices. Scoped to the iot subnet only."

  source = {
    zone_id         = unifi_firewall_zone.k8s_lab.id
    matching_target = "ANY"
  }

  destination = {
    zone_id         = data.unifi_firewall_zone.internal.id
    matching_target = "IP"
    ips             = ["10.3.0.0/24"]
  }
}

