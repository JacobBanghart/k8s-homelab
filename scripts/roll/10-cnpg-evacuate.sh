#!/usr/bin/env bash
# Phase 10: move CNPG primaries off the node.
# Their `-primary` PDBs are allowed=0 and will otherwise deadlock the drain.
# Idempotent: a node with no primaries is a no-op.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 10-cnpg-evacuate.sh <node>}"

moved=0
while read -r ns cluster pod node; do
  [[ "$node" == "$NODE" ]] || continue
  target=$(kubectl -n "$ns" get pods -l "cnpg.io/cluster=$cluster" \
             -o 'custom-columns=P:.metadata.name,N:.spec.nodeName' --no-headers 2>/dev/null \
           | awk -v n="$NODE" '$2!=n {print $1; exit}')
  [[ -n "$target" ]] || die "$ns/$cluster has no instance off $NODE to promote to"
  log "promoting $ns/$cluster -> $target"
  kubectl cnpg promote -n "$ns" "$cluster" "$target" >/dev/null 2>&1 \
    || die "kubectl-cnpg promote failed for $ns/$cluster (is the plugin installed?)"
  moved=1
done < <(kubectl get pods -A -l 'cnpg.io/instanceRole=primary' \
           -o 'custom-columns=NS:.metadata.namespace,C:.metadata.labels.cnpg\.io/cluster,P:.metadata.name,N:.spec.nodeName' \
           --no-headers 2>/dev/null)

if [[ $moved -eq 1 ]]; then
  sleep 30
  left=$(kubectl get pods -A -l 'cnpg.io/instanceRole=primary' \
           -o 'custom-columns=NS:.metadata.namespace,P:.metadata.name,N:.spec.nodeName' --no-headers 2>/dev/null \
         | awk -v n="$NODE" '$3==n {print $1"/"$2}')
  [[ -z "$left" ]] || die "primaries still on $NODE: $left"
  log "all CNPG primaries are off $NODE"
else
  log "no CNPG primaries on $NODE"
fi
