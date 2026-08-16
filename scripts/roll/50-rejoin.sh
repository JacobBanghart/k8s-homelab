#!/usr/bin/env bash
# Phase 50: bring the rebuilt VM back into the cluster.
#
# Join tokens expire after 24h and the certificate key after 2h, so the
# .join-commands.sh written at kubeadm-init time is useless for any later
# rejoin. Always re-mint from a surviving node.
#
# Idempotent: a node that is already Ready is a no-op.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 50-rejoin.sh <node>}"
IP=$(worker_ip "$NODE")

if node_exists "$NODE" && node_ready "$NODE"; then log "$NODE already Ready"; exit 0; fi

# A rebuilt VM has a new host key.
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
log "$NODE: waiting for ssh on $IP"
deadline=$(( $(date +%s) + READY_TIMEOUT ))
until nssh "$IP" true 2>/dev/null; do
  [[ $(date +%s) -lt $deadline ]] || die "$NODE: no ssh in ${READY_TIMEOUT}s"
  sleep 10
done
ssh-keyscan -t ed25519 "$IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
nssh "$IP" 'cloud-init status --wait >/dev/null 2>&1; true' || true

osrel=$(nssh "$IP" 'grep -oP "(?<=^PRETTY_NAME=\")[^\"]+" /etc/os-release' 2>/dev/null)
log "$NODE: booted $osrel"

src=""
for e in "${ALL_WORKERS[@]}"; do
  n="${e%%:*}"; [[ "$n" == "$NODE" ]] && continue
  node_ready "$n" && { src=$(cut -d: -f3 <<<"$e"); break; }
done
[[ -n "$src" ]] || die "no healthy worker to mint a join token from"

log "$NODE: refreshing ansible/.join-commands.sh from $src"
join=$(nssh "$src" 'sudo kubeadm token create --print-join-command' 2>/dev/null) \
  || die "could not create a join token from $src"
certkey=$(nssh "$src" 'sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1')
printf 'WORKER_JOIN_COMMAND="%s "\nCONTROL_PLANE_JOIN_COMMAND="%s --control-plane --certificate-key %s"\n' \
  "$join" "$join" "$certkey" > "$REPO_ROOT/ansible/.join-commands.sh"
chmod 600 "$REPO_ROOT/ansible/.join-commands.sh"

log "$NODE: running ansible"
(cd "$REPO_ROOT/ansible" && ansible-playbook playbook.yml --limit "$NODE" \
    --tags common,containerd,join-workers,unattended-upgrades) >/dev/null \
  || die "$NODE: ansible failed"
wait_node_ready "$NODE"
