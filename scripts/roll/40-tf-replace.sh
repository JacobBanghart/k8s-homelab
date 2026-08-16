#!/usr/bin/env bash
# Phase 40: point ONE node at a golden-image template and replace only that VM.
#
# clone.vm_id is ForceNew and template_vm_id is a single variable shared by
# every master and worker, so bumping it naively plans "6 to add, 0 to change,
# 6 to destroy" -- the whole cluster, Ceph OSD disks included, with no prompt.
# This refuses to apply unless the plan is exactly one replacement.
#
# Idempotent: if the VM already clones the requested template, it is a no-op.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 40-tf-replace.sh <node> <template-vmid>}"
TMPL="${2:?usage: 40-tf-replace.sh <node> <template-vmid>}"
TF="$REPO_ROOT/terraform"

current=$(cd "$TF" && terraform state show "proxmox_virtual_environment_vm.worker[\"$NODE\"]" 2>/dev/null \
          | awk '/vm_id[ ]*=/{last=$3} END{print last}')
if [[ "$current" == "$TMPL" ]]; then
  log "$NODE already built from template $TMPL"; exit 0
fi

log "$NODE: staging template_vm_id=$TMPL"
sed -i "/${NODE} = {/s|.*|    ${NODE} = { ip = \"$(worker_ip "$NODE")\", vm_id = $(worker_vmid "$NODE"), template_vm_id = ${TMPL} }|" \
  "$TF/variables.tf"
grep -q "${NODE} = .*template_vm_id = ${TMPL}" "$TF/variables.tf" \
  || die "failed to stage template_vm_id for $NODE in variables.tf"

plan=$(cd "$TF" && terraform plan -no-color -input=false 2>&1) || die "terraform plan failed"
echo "$plan" | grep -E "must be replaced|^Plan:" | sed 's/^/    /'
n=$(grep -cE "^  # .* must be replaced" <<<"$plan" || true)
[[ "$n" == "1" ]] || die "plan touches $n resources, expected exactly 1 -- ABORTING"
grep -qE "^Plan: 1 to add, 0 to change, 1 to destroy\.$" <<<"$plan" \
  || die "unexpected plan shape -- ABORTING"

log "$NODE: applying (exactly 1 replacement)"
(cd "$TF" && terraform apply -no-color -input=false -auto-approve \
    -target="proxmox_virtual_environment_vm.worker[\"$NODE\"]") >/dev/null \
  || die "$NODE: terraform apply failed"
log "$NODE: VM replaced from template $TMPL"
