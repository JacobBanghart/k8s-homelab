#!/usr/bin/env bash
# Phase 00: refuse to start unless the cluster is in a fit state.
# Idempotent: read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 00-preflight.sh <node>}"

command -v kubectl >/dev/null || die "kubectl not found"
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the cluster"

nr=$(kubectl get nodes --no-headers | awk '$2!="Ready" && $1!="'"$NODE"'" {print $1}')
[[ -z "$nr" ]] || die "other nodes not Ready: $nr"
cd=$(kubectl get nodes --no-headers | awk '/SchedulingDisabled/ && $1!="'"$NODE"'" {print $1}')
[[ -z "$cd" ]] || die "other nodes cordoned: $cd"

ceph health detail 2>/dev/null | grep -q '^HEALTH_ERR' && die "ceph is HEALTH_ERR"
t=$(ceph_num num_osds); u=$(ceph_num num_up_osds)
[[ "$t" == "$u" ]] || die "only $u/$t OSDs up -- fix Ceph before rolling $NODE"
log "preflight ok: $u/$t OSDs up, all other nodes Ready"

# THE gate: never start a node while another node's data is still moving.
require_ceph_clean "$NODE"
