#!/usr/bin/env bash
#
# Shared helpers for the roll phases. Sourced, never executed directly.
#
# Every phase script is expected to be IDEMPOTENT: safe to re-run after a
# partial failure without undoing work or double-applying anything. That is the
# whole point of the split -- a failure in phase 60 should not force you back
# through phases 00-50 by hand.

set -euo pipefail

ROLL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROLL_DIR/../.." && pwd)"
STATE_DIR="${ROLL_STATE_DIR:-$ROLL_DIR/.state}"

PVE_SSH="${PVE_SSH:-prox.mox}"
NODE_SSH_KEY="${NODE_SSH_KEY:-$HOME/.ssh/id_ed25519_k8s_homelab}"

READY_TIMEOUT="${READY_TIMEOUT:-900}"
CEPH_TIMEOUT="${CEPH_TIMEOUT:-5400}"
OSD_TIMEOUT="${OSD_TIMEOUT:-1800}"

# name:vmid:ip
ALL_WORKERS=(
  k8s-worker-0:9111:10.4.0.20
  k8s-worker-1:9112:10.4.0.21
  k8s-worker-2:9113:10.4.0.22
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--> %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

worker_vmid() { for e in "${ALL_WORKERS[@]}"; do [[ "${e%%:*}" == "$1" ]] && { cut -d: -f2 <<<"$e"; return; }; done; die "unknown worker: $1"; }
worker_ip()   { for e in "${ALL_WORKERS[@]}"; do [[ "${e%%:*}" == "$1" ]] && { cut -d: -f3 <<<"$e"; return; }; done; die "unknown worker: $1"; }

# --- phase state -------------------------------------------------------------
# One file per node listing completed phases, so a rerun resumes rather than
# restarting. Phases record themselves only on success.

phase_done()      { mkdir -p "$STATE_DIR"; grep -qxF "$2" "$STATE_DIR/$1" 2>/dev/null; }
phase_record()    { mkdir -p "$STATE_DIR"; grep -qxF "$2" "$STATE_DIR/$1" 2>/dev/null || echo "$2" >> "$STATE_DIR/$1"; }
phase_clear()     { rm -f "$STATE_DIR/$1"; }
phase_list()      { cat "$STATE_DIR/$1" 2>/dev/null || true; }

# --- ceph --------------------------------------------------------------------

# Resolve the tools pod on EVERY call and fail loudly if it is not Running.
# A Pending tools pod returns empty output rather than an error, which makes
# every health gate below silently pass. This bit us on 2026-08-09.
ceph() {
  local phase
  phase=$(kubectl -n rook-ceph get pods -l app=rook-ceph-tools \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Running" ]] \
    || die "rook-ceph-tools is '${phase:-missing}', not Running -- ceph output cannot be trusted"
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph "$@" 2>/dev/null
}

ceph_num()      { ceph osd stat -f json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"$1\"])"; }
ceph_total_pgs(){ ceph pg stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_summary"]["num_pgs"])'; }

# Fully clean means EVERY pg is active+clean. Deliberately not HEALTH_OK, which
# can be WARN for unrelated reasons (mon disk space) while data is fine, and can
# read green while backfill is merely queued.
#
# num_pg_by_state lives under pg_summary. Reading it from the top level yields
# an empty list which sums to 0 and makes this pass unconditionally -- so a
# missing key is an error, never "clean".
ceph_fully_clean() {
  local want clean
  want=$(ceph_total_pgs) || return 1
  clean=$(ceph pg stat -f json | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d["pg_summary"]["num_pg_by_state"]
if not s:
    raise SystemExit("pg stat returned no PG states")
print(sum(e["num"] for e in s if e["name"] == "active+clean"))
') || return 1
  [[ "$clean" == "$want" ]]
}

# THE gate. size=3/min_size=2 over exactly three hosts means two workers missing
# OSDs simultaneously drops PGs below min_size and blocks I/O cluster-wide.
require_ceph_clean() {
  local what="${1:-the next step}"
  log "gate: Ceph must be fully active+clean before $what (timeout ${CEPH_TIMEOUT}s)"
  local deadline=$(( $(date +%s) + CEPH_TIMEOUT ))
  until ceph_fully_clean; do
    [[ $(date +%s) -lt $deadline ]] || die "Ceph not clean in ${CEPH_TIMEOUT}s -- refusing to touch $what"
    sleep 30
  done
  log "gate cleared: $(ceph pg stat 2>/dev/null | cut -c1-60)"
}

noout_set()   { ceph osd set noout >/dev/null && log "noout set"; }
noout_clear() { ceph osd unset noout >/dev/null && log "noout cleared"; }
noout_is_set(){ ceph osd dump 2>/dev/null | grep -qE '^flags.*noout'; }

# The default 'balanced' mclock profile throttles recovery to protect client
# I/O. On an idle homelab that traded ~1.6 MiB/s for hours of degraded
# redundancy; high_recovery_ops gave 85 MiB/s.
recovery_fast()    { ceph config set osd osd_mclock_profile high_recovery_ops >/dev/null 2>&1 && log "recovery prioritised"; }
recovery_default() { ceph config set osd osd_mclock_profile balanced >/dev/null 2>&1 && log "recovery profile back to balanced"; }

# --- kubernetes --------------------------------------------------------------

node_exists() { kubectl get node "$1" >/dev/null 2>&1; }
node_ready()  { [[ "$(kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; }

wait_node_ready() {
  local name="$1" deadline=$(( $(date +%s) + READY_TIMEOUT ))
  log "$name: waiting for Ready (timeout ${READY_TIMEOUT}s)"
  until node_ready "$name"; do
    [[ $(date +%s) -lt $deadline ]] || die "$name: not Ready in ${READY_TIMEOUT}s"
    sleep 10
  done
  log "$name: Ready"
}

# --- ssh / proxmox -----------------------------------------------------------

pve()  { ssh -o BatchMode=yes "$PVE_SSH" "$@"; }
nssh() { local ip="$1"; shift; ssh -i "$NODE_SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "ansible@$ip" "$@"; }

# --- OSD disks ---------------------------------------------------------------
# Ceph 19/20 writes redundant BlueStore labels at 0, 1GiB, 10GiB, 100GiB, 1TiB.
# Zeroing only the start leaves deeper copies carrying the OLD OSD UUIDs, which
# then fight the new OSD: the osd pod's expand-bluefs init container aborts with
# "not all labels read properly, N!=M". Whether a rebuilt VM's disks come back
# blank at all is NON-DETERMINISTIC -- see docs/decisions.md. Always verify.
OSD_LABEL_OFFSETS="0 1073741824 10737418240 107374182400 1099511627776"

osd_disk_report() {
  nssh "$1" "for d in sdb sdc; do
      sz=\$(sudo blockdev --getsize64 /dev/\$d 2>/dev/null) || continue
      for off in $OSD_LABEL_OFFSETS; do
        [ \"\$off\" -ge \"\$sz\" ] && continue
        v=\$(sudo dd if=/dev/\$d bs=4096 count=1 skip=\$((off/4096)) status=none 2>/dev/null | tr -d '\\0' | wc -c)
        echo \"\$d \$off \$v\"
      done
    done" 2>/dev/null
}

osd_disks_blank() {
  local out; out=$(osd_disk_report "$1")
  [[ -n "$out" ]] || die "could not read OSD disks on $1"
  echo "$out" | sed 's/^/    /'
  ! awk '$3 != 0 {f=1} END {exit !f}' <<<"$out"
}

wipe_osd_disks() {
  local ip="$1"
  warn "wiping OSD disks on $ip -- ALL label offsets, not just the start"
  # blkdiscard is deliberately not used: it reports success while changing
  # nothing on these virtual disks.
  nssh "$ip" "for d in sdb sdc; do
      sz=\$(sudo blockdev --getsize64 /dev/\$d 2>/dev/null) || continue
      for off in $OSD_LABEL_OFFSETS; do
        [ \"\$off\" -ge \"\$sz\" ] && continue
        sudo dd if=/dev/zero of=/dev/\$d bs=1M count=8 seek=\$((off/1048576)) oflag=direct status=none 2>/dev/null
      done
      sudo dd if=/dev/zero of=/dev/\$d bs=1M count=200 oflag=direct status=none 2>/dev/null
      sudo sgdisk --zap-all /dev/\$d >/dev/null 2>&1
    done; sudo partprobe 2>/dev/null; sync" 2>/dev/null
}

osds_on_host() {
  ceph osd tree 2>/dev/null | awk -v h="$1" '
    $0 ~ "host "h {inhost=1; next}
    inhost && /host /{inhost=0}
    inhost && $1 ~ /^[0-9]+$/ {print $1}'
}

wait_osd_count() {
  local want="$1" deadline=$(( $(date +%s) + OSD_TIMEOUT ))
  log "waiting for $want OSDs up (timeout ${OSD_TIMEOUT}s)"
  until [[ "$(ceph_num num_up_osds)" == "$want" ]]; do
    [[ $(date +%s) -lt $deadline ]] || die "only $(ceph_num num_up_osds)/$want OSDs up after ${OSD_TIMEOUT}s"
    sleep 20
  done
  log "$want/$want OSDs up"
}
