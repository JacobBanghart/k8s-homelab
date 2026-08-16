#!/usr/bin/env bash
# Phase 70: clear noout. Also invoked from the orchestrator's EXIT trap, so a
# failed run never leaves Ceph's own recovery disabled.
# Idempotent: clearing an unset flag is harmless.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
noout_is_set || { log "noout already clear"; exit 0; }
noout_clear
noout_is_set && die "noout STILL set -- run: ceph osd unset noout"
exit 0
