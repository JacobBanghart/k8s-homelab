#!/usr/bin/env bash
#
# Roll the k8s workers one at a time, as a resumable sequence of phases.
#
# Each phase lives in scripts/roll/ and is independently runnable and
# idempotent, so a failure part-way through does not force you back to the
# start. Completed phases are recorded per node, and a rerun resumes.
#
#   --rebuild --template <vmid>   destroy and recreate the VM from a golden
#                                 image, then rebuild its OSDs. Slow, needs a
#                                 full Ceph backfill afterwards.
#   --reboot                      (default) stop/start the VM so pending
#                                 Proxmox config applies. Fast, keeps the OSDs.
#
# Phases:
#   reboot : 00 preflight, 10 cnpg-evacuate, 20 noout-set, [stop/start],
#            70 noout-clear, 80 ceph-settle
#   rebuild: 00 preflight, 10 cnpg-evacuate, 20 noout-set, 30 drain,
#            40 tf-replace, 50 rejoin, 60 osd-provision, 70 noout-clear,
#            80 ceph-settle
#
# Usage:
#   scripts/roll-workers.sh --dry-run
#   scripts/roll-workers.sh --rebuild --template 9001 k8s-worker-1
#   scripts/roll-workers.sh --rebuild --template 9001 --yes      # all workers
#   scripts/roll-workers.sh --status                             # show progress
#   scripts/roll-workers.sh --restart k8s-worker-1               # forget state
#   scripts/roll-workers.sh --only 60 --rebuild --template 9001 k8s-worker-1
#
# The hard rules, enforced rather than documented:
#   * ONE node at a time, and Ceph must be fully active+clean between nodes.
#     Two workers missing OSDs simultaneously drops PGs below min_size=2 and
#     blocks I/O cluster-wide. This is phase 00 and phase 80.
#   * noout is always cleared, including on the failure path (EXIT trap).
#   * A rebuild NEVER applies a terraform plan that touches more than one node.
#   * OSD disks are verified, never assumed (see docs/decisions.md).
#
set -euo pipefail

ROLL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/roll" && pwd)"
source "$ROLL_DIR/lib.sh"

MODE="reboot"; ASSUME_YES=0; DRY_RUN=0; TEMPLATE_VMID=""; ONLY=""; SHOW_STATUS=0; RESTART=0
SELECTED=()

usage() { sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)     MODE="reboot" ;;
    --rebuild)    MODE="rebuild" ;;
    --template)   TEMPLATE_VMID="${2:?--template needs a VMID}"; shift ;;
    --only)       ONLY="${2:?--only needs a phase number}"; shift ;;
    --status)     SHOW_STATUS=1 ;;
    --restart)    RESTART=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help)    usage ;;
    -*)           die "unknown flag: $1" ;;
    *)            SELECTED+=("$1") ;;
  esac
  shift
done
export ROLL_ASSUME_YES="$ASSUME_YES"

work=()
if [[ ${#SELECTED[@]} -eq 0 ]]; then work=("${ALL_WORKERS[@]}")
else
  for want in "${SELECTED[@]}"; do
    found=""
    for e in "${ALL_WORKERS[@]}"; do [[ "${e%%:*}" == "$want" ]] && found="$e"; done
    [[ -n "$found" ]] || die "unknown worker: $want"
    work+=("$found")
  done
fi

if [[ $SHOW_STATUS -eq 1 ]]; then
  log "phase state (from $STATE_DIR)"
  for e in "${work[@]}"; do
    n="${e%%:*}"; d=$(phase_list "$n")
    printf '  %-14s %s\n' "$n" "${d:-<nothing recorded>}" | tr '\n' ' '; echo
  done
  exit 0
fi

if [[ $RESTART -eq 1 ]]; then
  for e in "${work[@]}"; do phase_clear "${e%%:*}"; log "cleared state for ${e%%:*}"; done
fi

[[ "$MODE" == "rebuild" && -z "$TEMPLATE_VMID" ]] && die "--rebuild requires --template <vmid>"

if [[ "$MODE" == "rebuild" ]]; then
  PHASES=(00-preflight 10-cnpg-evacuate 20-noout-set 30-drain 40-tf-replace 50-rejoin 60-osd-provision 70-noout-clear 80-ceph-settle)
else
  PHASES=(00-preflight 10-cnpg-evacuate 20-noout-set 25-restart-vm 70-noout-clear 80-ceph-settle)
fi

# Safety net: whatever happens, do not leave Ceph's recovery disabled.
cleanup() { bash "$ROLL_DIR/70-noout-clear.sh" >/dev/null 2>&1 || warn "could not clear noout -- run: ceph osd unset noout"; }
trap cleanup EXIT INT TERM

log "mode=$MODE${TEMPLATE_VMID:+ template=$TEMPLATE_VMID}${ONLY:+ only=$ONLY}"
log "plan (one node at a time; Ceph must be clean between each):"
for e in "${work[@]}"; do
  n="${e%%:*}"; done_list=$(phase_list "$n" | tr '\n' ' ')
  printf '  %-14s vmid=%s\n' "$n" "$(cut -d: -f2 <<<"$e")"
  [[ -n "$done_list" ]] && printf '    already done: %s\n' "$done_list"
  for p in "${PHASES[@]}"; do
    phase_done "$n" "$p" && continue
    printf '    todo: %s\n' "$p"
  done
done
[[ $DRY_RUN -eq 1 ]] && { log "dry run, nothing changed"; exit 0; }

# The reboot-mode VM restart has no standalone phase script: it is three lines
# and needs the pending-config check inline to be meaningful.
restart_vm() {
  local name="$1" vmid; vmid=$(worker_vmid "$name")
  # Deliberately stop+start, not `qm reboot` and never `qm reset`: reset keeps
  # the same QEMU process and re-reads no config, so pending changes are
  # silently skipped. Do NOT drain or cordon for a reboot (see roll/30-drain).
  log "$name: stop/start vm $vmid"
  pve "qm shutdown $vmid --timeout 300" || die "$name: shutdown failed"
  pve "qm start $vmid" || die "$name: start failed"
  wait_node_ready "$name"
  local still
  still=$(pve "pvesh get /nodes/\$(hostname)/qemu/$vmid/pending --output-format json" 2>/dev/null \
          | python3 -c 'import json,sys
for e in json.load(sys.stdin):
    if "pending" in e: print("    %s: %s -> %s" % (e["key"], e.get("value"), e["pending"]))' || true)
  [[ -z "$still" ]] || { warn "$still"; die "$name: config STILL pending -- a guest-side reboot does not apply it"; }
  log "$name: pending config applied"
}

for e in "${work[@]}"; do
  name="${e%%:*}"

  if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "$MODE $name? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || { log "skipping $name"; continue; }
  fi

  for p in "${PHASES[@]}"; do
    [[ -n "$ONLY" && "$p" != "$ONLY"* ]] && continue
    if phase_done "$name" "$p"; then log "$name: $p already done, skipping"; continue; fi

    log "$name: --- $p ---"
    case "$p" in
      25-restart-vm)   restart_vm "$name" ;;
      40-tf-replace)   bash "$ROLL_DIR/40-tf-replace.sh" "$name" "$TEMPLATE_VMID" ;;
      70-noout-clear)  bash "$ROLL_DIR/70-noout-clear.sh" ;;
      *)               bash "$ROLL_DIR/$p.sh" "$name" ;;
    esac || die "$name: phase $p FAILED -- fix it, then rerun to resume from here"

    phase_record "$name" "$p"
  done

  log "$name: complete"
done

log "all requested workers rolled"
noout_is_set && die "noout is STILL set -- clear it: ceph osd unset noout"
log "noout clear; $(ceph pg stat 2>/dev/null | cut -c1-60)"
