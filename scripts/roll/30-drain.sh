#!/usr/bin/env bash
# Phase 30: drain and remove the node from Kubernetes.
# ONLY for rebuilds -- the node is about to be destroyed. Never drain to merely
# reboot a worker: the rook-ceph-osd PDB is maxUnavailable:1, so evicting the
# first OSD refuses the second forever and the drain hangs until timeout.
# Idempotent: an already-absent node is a no-op.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 30-drain.sh <node>}"

if ! node_exists "$NODE"; then log "$NODE already removed from the cluster"; exit 0; fi
log "$NODE: draining"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=420s >/dev/null \
  || die "$NODE: drain failed"
log "$NODE: deleting node object"
kubectl delete node "$NODE" --request-timeout=120s >/dev/null || true
node_exists "$NODE" && die "$NODE: node object still present after delete"
log "$NODE: removed from the cluster"
