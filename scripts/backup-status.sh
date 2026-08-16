#!/usr/bin/env bash
# Live status of the two offsite backup jobs (TrueNAS restic + Ceph RBD Job).
#
# restic only prints progress when stdout is a TTY, so a redirected log stays
# silent until the run finishes. S3 object count/size is the reliable live
# signal instead.
#
# Usage:  ./backup-status.sh          one shot
#         watch -n30 ./backup-status.sh
set -uo pipefail

TRUENAS="${TRUENAS_HOST:-root@10.1.0.45}"
NS=rook-ceph
JOB=ceph-rbd-offsite-backup
TFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform-aws-backup" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

BUCKET="$(cd "$TFDIR" && terraform output -raw bucket_name 2>/dev/null)"
REGION="$(cd "$TFDIR" && terraform output -raw aws_region 2>/dev/null || echo us-west-2)"

bold "=== S3  ${BUCKET:-<unknown>}"
if [ -n "${BUCKET:-}" ]; then
  aws s3 ls "s3://${BUCKET}" --recursive --summarize 2>/dev/null \
    | tail -2 \
    | sed 's/^/  /'
else
  echo "  (could not read bucket name from terraform output)"
fi

echo
bold "=== TrueNAS -> S3"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$TRUENAS" 'pgrep -f "restic backup" >/dev/null' 2>/dev/null; then
  echo "  status : RUNNING"
else
  echo "  status : idle / finished"
fi
ssh -o BatchMode=yes -o ConnectTimeout=5 "$TRUENAS" 'tail -c 400 /root/restic-backup.log 2>/dev/null' 2>/dev/null \
  | grep -vE '^\s*$' | tail -4 | sed 's/^/  /'

echo
bold "=== Ceph RBD -> S3"
POD=$(kubectl -n "$NS" get pod -l app="$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
PHASE=$(kubectl -n "$NS" get pod -l app="$JOB" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
echo "  pod    : ${POD:-not found} (${PHASE:-?})"
# Fetch by pod name with --tail=-1: `kubectl logs -l <selector>` silently
# truncates, which made this report 1 volume done when 26 were.
LOG=$(kubectl -n "$NS" logs "$POD" -c backup --tail=-1 2>/dev/null)
if [ -n "$LOG" ]; then
  DONE=$(printf '%s' "$LOG" | grep -cE '^OK:')
  FAILED=$(printf '%s' "$LOG" | grep -cE '^(BACKUP|SNAP) FAILED')
  TOTAL=$(kubectl -n "$NS" get cm ceph-backup-script \
            -o jsonpath='{.data.pvc-map\.txt}' 2>/dev/null | grep -c . )
  echo "  done   : ${DONE} ok, ${FAILED} failed (of ~${TOTAL} volumes + metadata)"
  printf '%s' "$LOG" | grep -E '^(===|OK:|SKIP:|.*FAILED)' | tail -3 | sed 's/^/  /'
fi

echo
bold "=== Follow live"
echo "  Ceph    : kubectl -n $NS logs -f ${POD:-<pod>} -c backup"
echo "  TrueNAS : ssh $TRUENAS 'tail -f /root/restic-backup.log'   # quiet until done"
echo "  Repo    : ssh $TRUENAS '. /root/.restic-env; restic snapshots --tag truenas-primary'"
