# walkv -- plan

## Contract

`walkv DB {put,get,del,bulk,verify-prefix,recover}`. The on-disk log format is
the part that must not change incompatibly:

```
u32 crc      CRC-32 of every byte after this field
u32 klen
u32 vlen     0xFFFFFFFF marks a tombstone
u8  key[klen]
u8  val[vlen]
```

## Hard invariant

**After any crash, the recovered state is a prefix with no holes.** Formally:
if `put kN` returned successfully, kN is present after recovery; and the set of
present keys is `{k0..kj-1}` for some j, never a set with a gap.

Plus **monotonicity**: `prefix(crash_at = i+1) >= prefix(crash_at = i)`.

## Oracle

Ranked by how little the author controls them:

1. `dm-log-writes` replay to every block-level flush boundary -- **not yet**,
   needs root. This is the real oracle and milestone 2 exists to reach it.
2. `t/crash.sh` -- process-level kill at every I/O boundary. 83 scenarios.
3. ASan + UBSan over the recovery parser, which reads post-crash bytes.
4. The monotonicity check, which catches ordering bugs the prefix check alone
   would pass.

## Non-goals

Concurrency and locking. Compaction. Range scans. Transactions across multiple
keys. Networking. Anything resembling a real database's feature list -- this
exists to be crashed, not to be used.

## Commit sequence

- [x] 00 WAL append with CRC, index, recovery that truncates at the first bad record
      files: walkv.c Makefile
      proves: `walkv db bulk 20 && walkv db verify-prefix 20` -> prefix 20
- [x] 01 crash injection hook (`WALKV_CRASH_AT`, `WALKV_TORN`)
      why: no way to test durability without the ability to die on command
- [x] 02 the harness: every boundary, both modes, plus monotonicity
      files: t/crash.sh
      proves: 83 scenarios, 0 failures
- [x] 03 fix: torn request at an fsync boundary must still crash
      why: half the torn scenarios were silently not crashing at all
- [x] 04 fix: truncate at the start of the bad record, not after the short read
      why: left a partial header for the next append to build on
- [x] 05 garbage-tail and bitflip scenarios
- [x] 06 ASan/UBSan run of the whole harness

### Milestone 1 -- make the store worth crashing

- [ ] 07 batch commit: group N puts into one fsync, and prove the prefix
      invariant still holds at batch granularity rather than record granularity
      why: this is where real stores get it wrong, and the harness should catch it
- [ ] 08 a deliberately broken variant behind `WALKV_BUG=no-dir-fsync` that skips
      the directory fsync after create
      why: **a harness nobody has seen fail is not evidence.** Prove the rig
      catches a known-planted bug before trusting it on an unknown one.
- [ ] 09 crash during recovery itself -- recovery must be idempotent and
      re-runnable, which is a separate invariant from the prefix property
- [ ] 10 log compaction, then crash at every boundary *during* compaction
      why: compaction is the single most dangerous operation in a log store

### Milestone 2 -- the real oracle

- [ ] 11 `dm-log-writes` capture: loop device, dm target, run the workload,
      capture the full block-level write stream
      note: needs root and a loop device, so it runs on the host, not in a container
- [ ] 12 replay the captured log to every *flush* boundary, mount, recover,
      assert the invariants at each one
      why: this tests what the device really guaranteed, not what the process
      thought it did. Catches reordering that `_exit` cannot.
- [ ] 13 `dm-flakey` pass: drop writes in a window rather than truncating cleanly
- [ ] 14 point the finished harness at a real project (sqlite in a non-default
      journal mode, or lmdb) and file whatever it finds

### Milestone 3

- [ ] 15 concurrent writers, and a linearizability check on the resulting history
- [ ] 16 property-based workload generation instead of the fixed k0..kN sequence,
      with the failing seed printed for replay

## Open questions

- The prefix invariant depends on the workload being strictly ordered. Once 07
  lands (batching) the invariant needs restating in terms of batches, and once
  15 lands (concurrency) it needs replacing with linearizability. Worth getting
  the batch version right before adding concurrency.
- Whether 08's planted bug should be a build flag or a runtime env var. Runtime
  is easier to test but means shipping known-broken code in the binary.
