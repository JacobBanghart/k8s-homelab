#!/usr/bin/env bash
#
# Roll the k8s workers one at a time, in one of two modes.
#
#   --reboot   (default) stop/start the VM so pending Proxmox config applies.
#              Fast, keeps the OSDs and their data.
#   --rebuild  destroy and recreate the VM from a golden image template.
#              Slow, destroys the OSD disks, needs a full Ceph backfill after.
#
# Every rule below was learned by breaking it. The point of a script is that it
# cannot forget them at 2am:
#
#   * ONE node at a time, and Ceph must be 177/177 active+clean between nodes.
#     Pools are size=3/min_size=2 over exactly three hosts, so two workers
#     missing OSDs simultaneously drops PGs below min_size and blocks I/O
#     cluster-wide. This is the single most important gate here.
#   * Do NOT drain to reboot. Each worker holds two OSDs and rook-ceph-osd's PDB
#     is maxUnavailable:1, so evicting the first OSD refuses the second forever.
#     (A rebuild does drain, because the node is being destroyed anyway.)
#   * Do NOT cordon for a reboot. A cordoned node cannot take its own OSDs back;
#     OSDs are pinned to the node holding their disk and are recreated, not
#     restarted.
#   * Do NOT use `qm reset`. Same QEMU process, re-reads no config, so pending
#     memory/balloon/disk changes are silently skipped.
#   * ALWAYS clear noout, including on the failure path. An aborted run that
#     leaves it set disables Ceph's own recovery until someone notices.
#   * NEVER cache the tools pod name. It gets rescheduled mid-procedure and a
#     stale name makes every `ceph` call return empty *without* an error, so
#     health gates silently pass.
#   * Move CNPG primaries off the node first. Their `-primary` PDBs are
#     allowed=0 and will otherwise deadlock the drain.
#   * VERIFY the OSD disks after a rebuild, never assume. Whether they come back
#     blank is non-deterministic (see docs/decisions.md).
#
# Usage:
#   scripts/roll-workers.sh                          # reboot all, prompt each
#   scripts/roll-workers.sh --rebuild k8s-worker-1   # rebuild one node
#   scripts/roll-workers.sh --rebuild --template 9001 --yes
#   scripts/roll-workers.sh --dry-run                # show plan, touch nothing
#
# Env:
#   PVE_SSH    ssh target for the Proxmox host (default: prox.mox)
#   NODE_SSH_KEY  ssh key for the nodes (default: ~/.ssh/id_ed25519_k8s_homelab)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PVE_SSH="${PVE_SSH:-prox.mox}"
NODE_SSH_KEY="${NODE_SSH_KEY:-$HOME/.ssh/id_ed25519_k8s_homelab}"

# name:vmid:ip
ALL_WORKERS=(
  k8s-worker-0:9111:10.4.0.20
  k8s-worker-1:9112:10.4.0.21
  k8s-worker-2:9113:10.4.0.22
)

MODE="reboot"
ASSUME_YES=0
DRY_RUN=0
TEMPLATE_VMID=""
SELECTED=()

NOOUT_SET=0
TUNED_RECOVERY=0
READY_TIMEOUT="${READY_TIMEOUT:-900}"
CEPH_TIMEOUT="${CEPH_TIMEOUT:-5400}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--> %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)     MODE="reboot" ;;
    --rebuild)    MODE="rebuild" ;;
    --template)   TEMPLATE_VMID="${2:?--template needs a VMID}"; shift ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help)    usage ;;
    -*)           die "unknown flag: $1" ;;
    *)            SELECTED+=("$1") ;;
  esac
  shift
done

# --- ceph plumbing -----------------------------------------------------------

# Resolve the tools pod every call and fail loudly if it is not Running. A
# Pending tools pod returns empty output rather than an error, which would make
# every health gate below trivially "pass".
ceph() {
  local phase
  phase=$(kubectl -n rook-ceph get pods -l app=rook-ceph-tools \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Running" ]] \
    || die "rook-ceph-tools is '${phase:-missing}', not Running -- ceph output cannot be trusted"
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph "$@" 2>/dev/null
}

cleanup() {
  if [[ $NOOUT_SET -eq 1 ]]; then
    log "clearing noout"
    ceph osd unset noout >/dev/null 2>&1 && NOOUT_SET=0 \
      || warn "FAILED to clear noout -- run: ceph osd unset noout"
  fi
  if [[ $TUNED_RECOVERY -eq 1 ]]; then
    log "restoring mclock profile to balanced"
    ceph config set osd osd_mclock_profile balanced >/dev/null 2>&1 || true
    TUNED_RECOVERY=0
  fi
}
trap cleanup EXIT INT TERM

total_pgs() { ceph pg stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_summary"]["num_pgs"])'; }

# Fully clean means every PG is active+clean. Not "HEALTH_OK" -- that can be
# WARN for unrelated reasons (mon disk space) while data is perfectly healthy,
# and it can read green while backfill is merely queued.
ceph_fully_clean() {
  local want states
  want=$(total_pgs) || return 1
  # NOTE: num_pg_by_state lives under pg_summary. Reading it from the top level
  # yields an empty list, which sums to 0 and makes this gate pass
  # unconditionally -- so treat a missing key as an error, never as "clean".
  states=$(ceph pg stat -f json | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d["pg_summary"]["num_pg_by_state"]
if not s:
    raise SystemExit("pg stat returned no PG states")
print(sum(e["num"] for e in s if e["name"] == "active+clean"))
') || return 1
  [[ "$states" == "$want" ]]
}

require_ceph_clean() {
  local what="$1"
  log "gate: waiting for Ceph fully active+clean before $what (timeout ${CEPH_TIMEOUT}s)"
  local deadline=$(( $(date +%s) + CEPH_TIMEOUT ))
  until ceph_fully_clean; do
    [[ $(date +%s) -lt $deadline ]] \
      || die "Ceph did not reach active+clean in ${CEPH_TIMEOUT}s -- refusing to touch $what"
    sleep 30
  done
  log "gate cleared: $(ceph pg stat 2>/dev/null | cut -c1-60)"
}

# The default 'balanced' mclock profile throttles recovery to protect client
# I/O. On an idle homelab that trades hours of degraded redundancy for nothing.
tune_recovery_up() {
  log "prioritising recovery (osd_mclock_profile=high_recovery_ops)"
  ceph config set osd osd_mclock_profile high_recovery_ops >/dev/null 2>&1 && TUNED_RECOVERY=1
}

# --- kubernetes plumbing -----------------------------------------------------

node_ready() {
  [[ "$(kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

wait_node_ready() {
  local name="$1" deadline=$(( $(date +%s) + READY_TIMEOUT ))
  log "$name: waiting for Ready (timeout ${READY_TIMEOUT}s)"
  until node_ready "$name"; do
    [[ $(date +%s) -lt $deadline ]] || die "$name: did not become Ready in ${READY_TIMEOUT}s"
    sleep 10
  done
  log "$name: Ready"
}

# CNPG's `-primary` PDB is allowed=0, so a primary on this node deadlocks the
# drain. Switch over to an instance that is somewhere else.
move_cnpg_primaries() {
  local name="$1" found=0
  log "$name: checking for CNPG primaries"
  while read -r ns cluster pod node; do
    [[ "$node" == "$name" ]] || continue
    found=1
    local target
    target=$(kubectl -n "$ns" get pods -l "cnpg.io/cluster=$cluster" \
               -o 'custom-columns=P:.metadata.name,N:.spec.nodeName' --no-headers 2>/dev/null \
             | awk -v n="$name" '$2!=n {print $1; exit}')
    [[ -n "$target" ]] || die "$ns/$cluster has no instance off $name to promote to"
    log "  promoting $ns/$cluster -> $target"
    kubectl cnpg promote -n "$ns" "$cluster" "$target" >/dev/null 2>&1 \
      || die "kubectl-cnpg promote failed for $ns/$cluster (plugin installed?)"
  done < <(kubectl get pods -A -l 'cnpg.io/instanceRole=primary' \
             -o 'custom-columns=NS:.metadata.namespace,C:.metadata.labels.cnpg\.io/cluster,P:.metadata.name,N:.spec.nodeName' \
             --no-headers 2>/dev/null)
  if [[ $found -eq 1 ]]; then
    sleep 30
    kubectl get pods -A -l 'cnpg.io/instanceRole=primary' \
      -o 'custom-columns=NS:.metadata.namespace,P:.metadata.name,N:.spec.nodeName' --no-headers 2>/dev/null \
      | awk -v n="$name" '$3==n {print "  STILL ON "n": "$1"/"$2}'
  else
    log "  none on this node"
  fi
}

# --- proxmox / terraform plumbing --------------------------------------------

pve() { ssh -o BatchMode=yes "$PVE_SSH" "$@"; }
nssh() { local ip="$1"; shift; ssh -i "$NODE_SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "ansible@$ip" "$@"; }

pending_summary() {
  pve "pvesh get /nodes/\$(hostname)/qemu/$1/pending --output-format json" 2>/dev/null \
    | python3 -c '
import json,sys
for e in json.load(sys.stdin):
    if "pending" in e: print("    %s: %s -> %s" % (e["key"], e.get("value"), e["pending"]))
' || true
}

# Point one node at a new template and apply ONLY that node. clone.vm_id is
# ForceNew and template_vm_id is shared fleet-wide, so a naive bump plans
# "6 to add, 6 to destroy" -- the whole cluster, OSD disks included. The plan is
# checked for exactly one replacement before anything is applied.
terraform_replace_node() {
  local name="$1" tmpl="$2"
  local tf="$REPO_ROOT/terraform"
  log "$name: staging template_vm_id=$tmpl"
  sed -i "/${name} = {/s|.*|    ${name} = { ip = \"$(worker_ip "$name")\", vm_id = $(worker_vmid "$name"), template_vm_id = ${tmpl} }|" \
    "$tf/variables.tf"
  local plan
  plan=$(cd "$tf" && terraform plan -no-color -input=false 2>&1) || die "terraform plan failed"
  local adds destroys
  adds=$(grep -cE "^  # .* must be replaced" <<<"$plan" || true)
  echo "$plan" | grep -E "must be replaced|^Plan:" | sed 's/^/    /'
  [[ "$adds" == "1" ]] || die "plan touches $adds resources, expected exactly 1 -- ABORTING"
  grep -qE "^Plan: 1 to add, 0 to change, 1 to destroy\." <<<"$plan" \
    || die "unexpected plan shape -- ABORTING"
  log "$name: applying (1 replacement)"
  (cd "$tf" && terraform apply -no-color -input=false -auto-approve \
      -target="proxmox_virtual_environment_vm.worker[\"$name\"]") >/dev/null \
    || die "$name: terraform apply failed"
}

# Ceph 19/20 writes redundant BlueStore labels at 0, 1GiB, 10GiB, 100GiB, 1TiB.
# Zeroing only the start leaves deeper copies carrying the OLD OSD UUIDs, which
# then fight the new OSD ("not all labels read properly, N!=M" in the osd pod's
# expand-bluefs init container). Report every offset; blank means ALL zero.
osd_disks_blank() {
  local ip="$1"
  local out
  out=$(nssh "$ip" 'for d in sdb sdc; do
      sz=$(sudo blockdev --getsize64 /dev/$d 2>/dev/null) || continue
      for off in 0 1073741824 10737418240 107374182400 1099511627776; do
        [ "$off" -ge "$sz" ] && continue
        v=$(sudo dd if=/dev/$d bs=4096 count=1 skip=$((off/4096)) status=none 2>/dev/null | tr -d "\0" | wc -c)
        echo "$d $off $v"
      done
    done' 2>/dev/null)
  echo "$out" | sed 's/^/    /'
  ! awk '$3 != 0 {found=1} END {exit !found}' <<<"$out"
}

wipe_osd_disks() {
  local ip="$1"
  warn "wiping OSD disks on $ip (all label offsets, not just the start)"
  nssh "$ip" 'for d in sdb sdc; do
      sz=$(sudo blockdev --getsize64 /dev/$d 2>/dev/null) || continue
      for off in 0 1073741824 10737418240 107374182400 1099511627776; do
        [ "$off" -ge "$sz" ] && continue
        sudo dd if=/dev/zero of=/dev/$d bs=1M count=8 seek=$((off/1048576)) oflag=direct status=none 2>/dev/null
      done
      sudo dd if=/dev/zero of=/dev/$d bs=1M count=200 oflag=direct status=none 2>/dev/null
      sudo sgdisk --zap-all /dev/$d >/dev/null 2>&1
    done; sudo partprobe 2>/dev/null; sync' 2>/dev/null
  # blkdiscard is deliberately not used: it reports success while changing
  # nothing on these virtual disks.
}

osds_on_host() {
  ceph osd tree 2>/dev/null | awk -v h="$1" '
    $0 ~ "host "h {inhost=1; next}
    inhost && /host /{inhost=0}
    inhost && $1 ~ /^[0-9]+$/ {print $1}'
}

purge_host_osds() {
  local name="$1"
  local ids; ids=$(osds_on_host "$name")
  [[ -n "$ids" ]] || { log "$name: no OSDs to purge"; return 0; }
  log "$name: purging OSDs: $(tr '\n' ' ' <<<"$ids")"
  for o in $ids; do kubectl -n rook-ceph scale deploy "rook-ceph-osd-$o" --replicas=0 >/dev/null 2>&1 || true; done
  sleep 10
  for o in $ids; do ceph osd purge "$o" --yes-i-really-mean-it >/dev/null 2>&1 || true; done
  for o in $ids; do kubectl -n rook-ceph delete deploy "rook-ceph-osd-$o" --ignore-not-found >/dev/null 2>&1 || true; done
  kubectl -n rook-ceph delete job -l app=rook-ceph-osd-prepare --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator >/dev/null 2>&1 || true
}

wait_osd_count() {
  local want="$1" deadline=$(( $(date +%s) + 1800 ))
  log "waiting for $want OSDs up"
  until [[ "$(ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_up_osds"])')" == "$want" ]]; do
    [[ $(date +%s) -lt $deadline ]] || die "only $(ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_up_osds"])') OSDs up, expected $want"
    sleep 20
  done
  log "$want/$want OSDs up"
}

# Join tokens expire after 24h and the certificate key after 2h, so the file
# written at kubeadm-init time is useless for any later rejoin.
refresh_join_commands() {
  local src_ip="$1"
  log "refreshing ansible/.join-commands.sh (tokens expire)"
  local join certkey
  join=$(nssh "$src_ip" 'sudo kubeadm token create --print-join-command' 2>/dev/null) \
    || die "could not create a join token from $src_ip"
  certkey=$(nssh "$src_ip" 'sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1')
  printf 'WORKER_JOIN_COMMAND="%s "\nCONTROL_PLANE_JOIN_COMMAND="%s --control-plane --certificate-key %s"\n' \
    "$join" "$join" "$certkey" > "$REPO_ROOT/ansible/.join-commands.sh"
  chmod 600 "$REPO_ROOT/ansible/.join-commands.sh"
}

rejoin_node() {
  local name="$1" ip="$2"
  # The rebuilt VM has a new host key; ansible ignores this but ssh-based checks
  # here do not.
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  log "$name: waiting for ssh"
  until nssh "$ip" true 2>/dev/null; do sleep 10; done
  ssh-keyscan -t ed25519 "$ip" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  nssh "$ip" 'cloud-init status --wait >/dev/null 2>&1; true' || true
  log "$name: running ansible (common, containerd, join-workers, unattended-upgrades)"
  (cd "$REPO_ROOT/ansible" && ansible-playbook playbook.yml --limit "$name" \
      --tags common,containerd,join-workers,unattended-upgrades) >/dev/null \
    || die "$name: ansible failed"
}

worker_vmid() { for e in "${ALL_WORKERS[@]}"; do [[ "${e%%:*}" == "$1" ]] && { echo "$e" | cut -d: -f2; return; }; done; }
worker_ip()   { for e in "${ALL_WORKERS[@]}"; do [[ "${e%%:*}" == "$1" ]] && { echo "$e" | cut -d: -f3; return; }; done; }

# --- preflight ---------------------------------------------------------------

log "preflight (mode: $MODE)"
command -v kubectl >/dev/null || die "kubectl not found"
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the cluster"
[[ "$MODE" == "rebuild" ]] && { command -v terraform >/dev/null || die "terraform not found"; \
                               command -v ansible-playbook >/dev/null || die "ansible-playbook not found"; \
                               [[ -n "$TEMPLATE_VMID" ]] || die "--rebuild requires --template <vmid>"; }

not_ready=$(kubectl get nodes --no-headers | awk '$2!="Ready" {print $1}')
[[ -z "$not_ready" ]] || die "these nodes are not Ready, refusing to start: $not_ready"
cordoned=$(kubectl get nodes --no-headers | awk '/SchedulingDisabled/ {print $1}')
[[ -z "$cordoned" ]] || die "these nodes are cordoned, resolve first: $cordoned"

TOTAL_OSDS=$(ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_osds"])')
UP_OSDS=$(ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_up_osds"])')
[[ "$TOTAL_OSDS" == "$UP_OSDS" ]] || die "only $UP_OSDS/$TOTAL_OSDS OSDs up -- fix Ceph first"
ceph health detail | grep -q "^HEALTH_ERR" && die "ceph is HEALTH_ERR -- refusing to roll"
log "cluster Ready, $UP_OSDS/$TOTAL_OSDS OSDs up"

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

log "plan (strictly one at a time, Ceph must be clean between each):"
for e in "${work[@]}"; do
  n="${e%%:*}"; v=$(cut -d: -f2 <<<"$e")
  echo "  $n (vmid $v)  mode=$MODE${TEMPLATE_VMID:+ template=$TEMPLATE_VMID}"
  [[ "$MODE" == "reboot" ]] && pending_summary "$v"
done
[[ $DRY_RUN -eq 1 ]] && { log "dry run, nothing changed"; exit 0; }

# --- the roll ----------------------------------------------------------------

for e in "${work[@]}"; do
  name="${e%%:*}"; vmid=$(cut -d: -f2 <<<"$e"); ip=$(cut -d: -f3 <<<"$e")

  if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "$MODE $name (vmid $vmid)? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log "skipping $name"; continue; }
  fi

  # THE gate. Never start a node while the previous one's data is still moving.
  require_ceph_clean "$name"
  move_cnpg_primaries "$name"

  log "$name: setting noout"
  ceph osd set noout >/dev/null; NOOUT_SET=1

  if [[ "$MODE" == "reboot" ]]; then
    # Deliberately stop+start, not `qm reboot`: an explicit stop makes the
    # pending-config check below meaningful, and `qm reset` re-reads nothing.
    # Do NOT drain and do NOT cordon here (see header).
    log "$name: stop/start vm $vmid"
    pve "qm shutdown $vmid --timeout 300" || die "$name: shutdown failed"
    pve "qm start $vmid" || die "$name: start failed"
    wait_node_ready "$name"
    still=$(pending_summary "$vmid")
    [[ -z "$still" ]] || { warn "$still"; die "$name: config STILL pending after restart -- a guest-side reboot does not apply it"; }
    log "$name: pending config applied"
  else
    log "$name: draining (node is being destroyed)"
    kubectl drain "$name" --ignore-daemonsets --delete-emptydir-data --force --timeout=420s >/dev/null \
      || die "$name: drain failed"
    kubectl delete node "$name" --request-timeout=120s >/dev/null || true
    terraform_replace_node "$name" "$TEMPLATE_VMID"

    # Pick a surviving node to mint a fresh join token from.
    src=""
    for o in "${ALL_WORKERS[@]}"; do
      [[ "${o%%:*}" == "$name" ]] && continue
      node_ready "${o%%:*}" && { src=$(cut -d: -f3 <<<"$o"); break; }
    done
    [[ -n "$src" ]] || die "no healthy node to mint a join token from"
    refresh_join_commands "$src"
    rejoin_node "$name" "$ip"
    wait_node_ready "$name"

    log "$name: verifying OSD disks (never assume -- see docs/decisions.md)"
    if osd_disks_blank "$ip"; then
      log "$name: disks are genuinely blank -> purging old OSD IDs, Rook will provision fresh"
      purge_host_osds "$name"
    else
      warn "$name: disks still carry BlueStore labels."
      warn "  Either let the OSDs re-adopt (no backfill), or wipe every offset first."
      warn "  Purging now WITHOUT a full wipe is what cost hours on worker-1."
      if [[ $ASSUME_YES -eq 1 ]]; then
        wipe_osd_disks "$ip"; osd_disks_blank "$ip" || die "$name: disks still not blank after wipe"
        purge_host_osds "$name"
      else
        read -r -p "  wipe all label offsets and purge? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          wipe_osd_disks "$ip"; osd_disks_blank "$ip" || die "$name: disks still not blank after wipe"
          purge_host_osds "$name"
        else
          log "$name: leaving disks alone, waiting for OSDs to re-adopt"
        fi
      fi
    fi
    wait_osd_count "$TOTAL_OSDS"
  fi

  cleanup                 # clears noout
  tune_recovery_up        # idle cluster: do not let backfill crawl
  log "$name: done; waiting for Ceph before the next node"
  require_ceph_clean "the next node"
  cleanup                 # restores balanced profile
done

log "all requested workers rolled"
ceph osd dump 2>/dev/null | grep -q "flags.*noout" && die "noout is STILL set -- clear it"
log "noout confirmed clear; $(ceph pg stat 2>/dev/null | cut -c1-60)"
