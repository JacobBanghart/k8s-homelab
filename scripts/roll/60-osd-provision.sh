#!/usr/bin/env bash
# Phase 60: get this node's OSDs back.
#
# Whether a rebuilt VM's OSD disks come back blank is NON-DETERMINISTIC: on
# 2026-08-15 worker-1 kept its BlueStore data across a terraform replace while
# worker-2, rebuilt the same way hours later, came back completely blank. The
# nvme datastore is dir-backed, so whether a reallocated raw file reads as zeros
# or as the previous blocks is up to the host filesystem. VERIFY, never assume.
#
# Idempotent: if the expected OSD count is already up, it is a no-op.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 60-osd-provision.sh <node> [expected-osd-total]}"
WANT="${2:-}"
IP=$(worker_ip "$NODE")
AUTO="${ROLL_ASSUME_YES:-0}"

[[ -n "$WANT" ]] || WANT=$(( $(ceph_num num_osds) ))
if [[ "$(ceph_num num_up_osds)" == "$WANT" ]] && [[ -n "$(osds_on_host "$NODE")" ]]; then
  log "$NODE already has its OSDs and $WANT/$WANT are up"; exit 0
fi

log "$NODE: inspecting OSD disks at every BlueStore label offset"
if osd_disks_blank "$IP"; then
  log "$NODE: disks are genuinely blank -> purge old OSD IDs, Rook provisions fresh"
else
  warn "$NODE: disks still carry BlueStore labels (old OSD UUIDs)."
  warn "  Options: let them re-adopt (no backfill), or wipe EVERY offset then purge."
  warn "  Purging without a full wipe is what cost hours on worker-1:"
  warn "    expand-bluefs aborts with 'not all labels read properly'."
  if [[ "$AUTO" == "1" ]]; then
    wipe_osd_disks "$IP"
  else
    read -r -p "  wipe all label offsets and purge? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || { log "$NODE: leaving disks alone; waiting for OSDs to re-adopt"; wait_osd_count "$WANT"; exit 0; }
    wipe_osd_disks "$IP"
  fi
  osd_disks_blank "$IP" >/dev/null || die "$NODE: disks STILL not blank after wipe"
  log "$NODE: wipe verified clean at every offset"
fi

ids=$(osds_on_host "$NODE")
if [[ -n "$ids" ]]; then
  log "$NODE: purging stale OSD IDs: $(tr '\n' ' ' <<<"$ids")"
  for o in $ids; do kubectl -n rook-ceph scale deploy "rook-ceph-osd-$o" --replicas=0 >/dev/null 2>&1 || true; done
  sleep 10
  for o in $ids; do ceph osd purge "$o" --yes-i-really-mean-it >/dev/null 2>&1 || true; done
  for o in $ids; do kubectl -n rook-ceph delete deploy "rook-ceph-osd-$o" --ignore-not-found >/dev/null 2>&1 || true; done
fi
# Stale prepare jobs are read back by the operator; clear them or it re-adopts
# the very state we just removed.
kubectl -n rook-ceph delete job -l app=rook-ceph-osd-prepare --ignore-not-found >/dev/null 2>&1 || true
kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator >/dev/null 2>&1 || true
log "$NODE: operator restarted, waiting for Rook to provision"
wait_osd_count "$WANT"
