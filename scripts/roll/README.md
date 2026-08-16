# Rolling workers: phases, resumption, and who fixes what

`scripts/roll-workers.sh` is an orchestrator. The actual work lives in numbered
phase scripts in this directory. Each one is independently runnable and
idempotent, so a failure part-way through does not force you back to the start.

```
00-preflight       cluster Ready, all OSDs up, Ceph fully active+clean
10-cnpg-evacuate   move CNPG primaries off the node
20-noout-set       stop Ceph marking this node's OSDs out
30-drain           drain + delete the node object      (rebuild only)
40-tf-replace      replace exactly ONE VM from a template (rebuild only)
50-rejoin          re-mint join token, run ansible, wait Ready (rebuild only)
60-osd-provision   verify disks, purge/wipe, wait for OSDs  (rebuild only)
25-restart-vm      stop/start the VM                   (reboot only, inline)
70-noout-clear     clear noout (also runs from the EXIT trap)
80-ceph-settle     wait for full redundancy before the next node
```

## Resuming

Completed phases are recorded per node under `.state/<node>` (gitignored). A
rerun skips what is already done:

```bash
scripts/roll-workers.sh --status
scripts/roll-workers.sh --rebuild --template 9001 k8s-worker-1   # resumes
scripts/roll-workers.sh --restart k8s-worker-1                   # forget state
scripts/roll-workers.sh --only 60 --rebuild --template 9001 k8s-worker-1
```

A phase records itself **only on success**, so if `60-osd-provision` fails you
fix the cause and rerun; phases 00-50 are skipped.

## The rules this enforces

These are not style preferences. Every one of them was learned by breaking it,
and the details are in `docs/decisions.md`.

- **One node at a time, Ceph fully `active+clean` between nodes.** Pools are
  `size=3, min_size=2` across exactly three hosts, so two workers missing OSDs
  simultaneously drops PGs below `min_size` and blocks I/O cluster-wide. This is
  phases 00 and 80 and it is the most important thing here.
- **`noout` is always cleared**, including on the failure path, via the
  orchestrator's EXIT trap. An aborted run that leaves it set silently disables
  Ceph's own recovery.
- **A rebuild never applies a plan touching more than one node.** `clone.vm_id`
  is ForceNew and `template_vm_id` is shared fleet-wide, so an unchecked bump
  plans `6 to add, 6 to destroy` — every master and worker, OSD disks included.
  Phase 40 aborts unless the plan is exactly `1 to add, 0 to change, 1 to
  destroy`.
- **OSD disks are verified, never assumed.** Whether a rebuilt VM's disks come
  back blank is non-deterministic. Phase 60 reads every BlueStore label offset
  (0, 1 GiB, 10 GiB, 100 GiB, 1 TiB) and decides from that.
- **Wipes cover the whole device.** Zeroing only the start leaves deeper labels
  carrying old OSD UUIDs, and the new OSD then aborts in `expand-bluefs` with
  "not all labels read properly". `blkdiscard` is deliberately unused: it
  reports success while changing nothing on these virtual disks.
- **Never drain or cordon to merely reboot.** The `rook-ceph-osd` PDB is
  `maxUnavailable: 1`, so evicting the first OSD refuses the second forever, and
  a cordoned node cannot take its own OSDs back.
- **Never `qm reset`.** Same QEMU process, re-reads no config, so pending
  changes are silently skipped.
- **Join tokens expire** (24h; certificate key 2h). Phase 50 always re-mints
  from a surviving node rather than trusting `.join-commands.sh`.
- **Never cache the tools pod name.** A Pending tools pod returns empty output
  rather than an error, so health gates pass silently. `lib.sh:ceph()` re-checks
  it on every call.

## Division of labour with the agent loop

The split is deliberate:

- **The scripts own the mechanics and the gates.** Anything that can be checked
  by a machine belongs here, not in someone's head. The failures worth
  preventing are mechanical: a partial wipe, a missed gate, a forgotten `noout`,
  trusting `tail`'s exit code instead of the command's.
- **The agent loop owns judgement and improvement.** Its job when a phase fails
  is *not* to hand-run the remaining steps. It is to:
  1. Diagnose the failure from primary evidence — read the failing container's
     log, not the pod state; read the real exit code, not a pipeline's.
  2. Fix the underlying cause.
  3. **Change the phase script so the same failure cannot recur**, and add the
     check that would have caught it.
  4. Rerun the orchestrator to resume from the failed phase.

If the loop finds itself doing something by hand that the script could have
done, that is a bug in the script. Fix the script.

## Known gap

The `--rebuild` path has been exercised phase-by-phase against the live cluster
(the gate correctly refuses mid-backfill, the disk check correctly finds labels
at all offsets on a live OSD, the plan guard rejects anything but a single
replacement, resume skips completed phases), but has not yet been run
end-to-end. The 2026-08-15 migration of all six nodes to Ubuntu 26.04 was done
by hand; this codifies it. Run with `--dry-run` first, and without `--yes` so
phase 60 prompts before wiping anything.
