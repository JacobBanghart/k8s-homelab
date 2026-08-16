#!/usr/bin/env bash
# Phase 80: wait for Ceph to restore full redundancy before the next node.
# Idempotent: returns immediately if already clean.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NODE="${1:?usage: 80-ceph-settle.sh <node>}"
if ceph_fully_clean; then log "Ceph already fully clean"; recovery_default; exit 0; fi
recovery_fast
require_ceph_clean "the next node (after $NODE)"
recovery_default
