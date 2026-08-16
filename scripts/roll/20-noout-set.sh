#!/usr/bin/env bash
# Phase 20: stop Ceph marking this node's OSDs out while it is away.
# Idempotent: setting an already-set flag is harmless.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 20-noout-set.sh <node>}"
noout_is_set && { log "noout already set"; exit 0; }
noout_set
