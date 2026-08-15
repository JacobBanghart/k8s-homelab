#!/usr/bin/env bash
#
# Roll the k8s workers one at a time, applying any pending Proxmox config.
#
# This automates docs/runbook.md "Rebooting a worker: the drain cannot
# complete". The rules encoded here were all learned the hard way; the point of
# a script is that it cannot forget them mid-procedure:
#
#   * Do NOT drain. Each worker holds two OSDs and rook-ceph-osd's PDB is
#     maxUnavailable:1, so evicting the first OSD refuses the second forever.
#     Separately, the workers can sit near 100% of allocatable memory requests,
#     in which case the pods have nowhere to land regardless of PDBs.
#   * Do NOT cordon. A cordoned node cannot take its own OSDs back, because
#     OSDs are pinned to the node holding their disk and are recreated rather
#     than restarted.
#   * Do NOT use `qm reset`. Same QEMU process, so it re-reads nothing --
#     pending memory/balloon/disk changes are silently skipped. Full stop+start.
#   * ALWAYS clear `noout`, including on the failure path. An aborted run that
#     leaves it set disables Ceph's own recovery until someone notices.
#   * NEVER cache the tools pod name. It gets rescheduled mid-procedure, and a
#     stale name makes every `ceph` call return empty *without* an error, so
#     health gates silently pass.
#
# Usage:
#   scripts/roll-workers.sh                    # all workers, prompt each
#   scripts/roll-workers.sh k8s-worker-1       # just one
#   scripts/roll-workers.sh --yes              # no prompts
#   scripts/roll-workers.sh --dry-run          # show plan, touch nothing
#
# Env:
#   PVE_SSH   ssh target for the Proxmox host (default: prox.mox)
#
set -euo pipefail

PVE_SSH="${PVE_SSH:-prox.mox}"

# name:vmid
ALL_WORKERS=(
  k8s-worker-0:9111
  k8s-worker-1:9112
  k8s-worker-2:9113
)

ASSUME_YES=0
DRY_RUN=0
SELECTED=()

NOOUT_SET=0
READY_TIMEOUT="${READY_TIMEOUT:-600}"   # seconds to wait for a node to return
CEPH_TIMEOUT="${CEPH_TIMEOUT:-1800}"    # seconds to wait for Ceph to settle

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--> %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)    ASSUME_YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help)   usage ;;
    -*)          die "unknown flag: $1" ;;
    *)           SELECTED+=("$1") ;;
  esac
  shift
done

# --- ceph plumbing -----------------------------------------------------------

# Resolve the tools pod on every call, and fail loudly if it is not Running.
# A Pending tools pod returns empty output rather than an error, which would
# make every health gate below trivially "pass".
ceph() {
  local phase
  phase=$(kubectl -n rook-ceph get pods -l app=rook-ceph-tools \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Running" ]] \
    || die "rook-ceph-tools is '${phase:-missing}', not Running -- ceph output cannot be trusted"
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph "$@" 2>/dev/null
}

clear_noout() {
  if [[ $NOOUT_SET -eq 1 ]]; then
    log "clearing noout"
    if ceph osd unset noout; then
      NOOUT_SET=0
    else
      warn "FAILED to clear noout -- do this by hand:"
      warn "  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout"
    fi
  fi
}
trap clear_noout EXIT INT TERM

# Total OSDs is discovered, not hardcoded, so this keeps working if the
# cluster grows.
osd_total() { ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_osds"])'; }
osd_up()    { ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_up_osds"])'; }

# "Settled" means every OSD is up AND no PG is degraded/misplaced/peering.
# `HEALTH_OK` alone is not enough: it can flip green while backfill is queued.
ceph_settled() {
  local want="$1" up pgs
  up=$(osd_up) || return 1
  [[ "$up" == "$want" ]] || return 1
  # NOTE: num_pg_by_state lives under pg_summary. Reading it from the top level
  # yields an empty list, which sums to 0 and makes this gate pass
  # unconditionally -- so treat a missing key as an error, never as "clean".
  pgs=$(ceph pg stat -f json | python3 -c '
import json, sys
UNSETTLED = ("degraded", "misplaced", "peering", "recovering", "backfilling")
d = json.load(sys.stdin)
states = d["pg_summary"]["num_pg_by_state"]
if not states:
    raise SystemExit("pg stat returned no PG states")
bad = sum(e["num"] for e in states
          if any(k in e["name"] for k in UNSETTLED))
print(bad)
') || return 1
  [[ "$pgs" == "0" ]]
}

# --- proxmox plumbing --------------------------------------------------------

pve() { ssh -o BatchMode=yes "$PVE_SSH" "$@"; }

pending_summary() {
  local vmid="$1"
  pve "pvesh get /nodes/\$(hostname)/qemu/$vmid/pending --output-format json" 2>/dev/null \
    | python3 -c '
import json,sys
for e in json.load(sys.stdin):
    if "pending" in e:
        print("    %s: %s -> %s" % (e["key"], e.get("value"), e["pending"]))
' || true
}

# --- preflight ---------------------------------------------------------------

log "preflight"

command -v kubectl >/dev/null || die "kubectl not found"
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the cluster"

not_ready=$(kubectl get nodes --no-headers | awk '$2!="Ready" {print $1}')
[[ -z "$not_ready" ]] || die "these nodes are not Ready, refusing to start: $not_ready"

cordoned=$(kubectl get nodes --no-headers | awk '/SchedulingDisabled/ {print $1}')
[[ -z "$cordoned" ]] || die "these nodes are cordoned, resolve first: $cordoned"

TOTAL_OSDS=$(osd_total) || die "cannot read osd stat"
UP_OSDS=$(osd_up)
[[ "$TOTAL_OSDS" == "$UP_OSDS" ]] \
  || die "only $UP_OSDS/$TOTAL_OSDS OSDs are up -- fix Ceph before rolling"
log "cluster Ready, $UP_OSDS/$TOTAL_OSDS OSDs up"

if ceph health detail | grep -q "^HEALTH_ERR"; then
  die "ceph is HEALTH_ERR -- refusing to roll"
fi

# Build the work list.
work=()
if [[ ${#SELECTED[@]} -eq 0 ]]; then
  work=("${ALL_WORKERS[@]}")
else
  for want in "${SELECTED[@]}"; do
    found=""
    for entry in "${ALL_WORKERS[@]}"; do
      [[ "${entry%%:*}" == "$want" ]] && found="$entry"
    done
    [[ -n "$found" ]] || die "unknown worker: $want"
    work+=("$found")
  done
fi

log "plan (strictly one at a time):"
for entry in "${work[@]}"; do
  name="${entry%%:*}"; vmid="${entry##*:}"
  echo "  $name (vmid $vmid)"
  pending_summary "$vmid"
done

if [[ $DRY_RUN -eq 1 ]]; then
  log "dry run, nothing changed"
  exit 0
fi

# --- the roll ----------------------------------------------------------------

for entry in "${work[@]}"; do
  name="${entry%%:*}"; vmid="${entry##*:}"

  if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "roll $name (vmid $vmid)? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log "skipping $name"; continue; }
  fi

  log "$name: checking for CNPG primaries"
  primaries=$(kubectl get pods -A -l 'cnpg.io/instanceRole=primary' \
                -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.labels.cnpg\.io/cluster}/{.spec.nodeName}{"\n"}{end}' \
                2>/dev/null | awk -F/ -v n="$name" '$3==n {print $1"/"$2}' | sort -u || true)
  if [[ -n "$primaries" ]]; then
    for p in $primaries; do
      ns="${p%%/*}"; cl="${p##*/}"
      log "  switching over $ns/$cl"
      kubectl cnpg promote -n "$ns" "$cl" --help >/dev/null 2>&1 \
        || die "kubectl-cnpg plugin not installed; move $ns/$cl by hand first"
      kubectl cnpg promote -n "$ns" "$cl" &&
        sleep 20
    done
  else
    log "  none on this node"
  fi

  log "$name: setting noout"
  ceph osd set noout
  NOOUT_SET=1

  # Deliberately stop+start rather than `qm reboot`: an explicit stop makes the
  # "did the pending config apply" check below meaningful, and `qm reset` would
  # not re-read the config at all.
  log "$name: stopping vm $vmid"
  pve "qm shutdown $vmid --timeout 300" || die "$name: shutdown failed"
  log "$name: starting vm $vmid"
  pve "qm start $vmid" || die "$name: start failed"

  log "$name: waiting for Ready (timeout ${READY_TIMEOUT}s)"
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  until kubectl get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
    [[ $(date +%s) -lt $deadline ]] || die "$name: did not become Ready in ${READY_TIMEOUT}s"
    sleep 10
  done
  log "$name: Ready"

  # Confirm the pending config actually took. This is the check that catches a
  # guest-side reboot having been used instead of a hypervisor stop+start.
  still_pending=$(pending_summary "$vmid")
  if [[ -n "$still_pending" ]]; then
    warn "$name: config changes are STILL pending after restart:"
    warn "$still_pending"
    die "$name: expected the restart to apply them -- investigate before continuing"
  fi
  log "$name: pending config applied"

  log "$name: waiting for Ceph to settle (timeout ${CEPH_TIMEOUT}s)"
  deadline=$(( $(date +%s) + CEPH_TIMEOUT ))
  until ceph_settled "$TOTAL_OSDS"; do
    [[ $(date +%s) -lt $deadline ]] || die "$name: Ceph did not settle in ${CEPH_TIMEOUT}s"
    sleep 15
  done
  log "$name: $TOTAL_OSDS/$TOTAL_OSDS OSDs up, no degraded/misplaced PGs"

  clear_noout
  log "$name: done"
done

log "all requested workers rolled"
# Belt and braces: prove noout is not set, rather than assuming the trap ran.
if ceph osd dump 2>/dev/null | grep -q "flags.*noout"; then
  die "noout is STILL set -- clear it: ceph osd unset noout"
fi
log "noout confirmed clear"
