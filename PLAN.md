# walkv: plan

## Contract

`walkv DB {put,get,del,bulk,batch,compact,verify-prefix,recover}`. The on-disk
log format is the part that must not change incompatibly:

```
u32 crc      CRC-32 of every byte after this field
u32 klen
u32 vlen     0xFFFFFFFF marks a tombstone
u8  key[klen]
u8  val[vlen]
```

## Hard invariant

After any crash, the recovered state is a prefix with no holes. Formally:
if `put kN` returned successfully, kN is present after recovery, and the set of
present keys is `{k0..kj-1}` for some j, never a set with a gap.

Plus monotonicity: `prefix(crash_at = i+1) >= prefix(crash_at = i)`.

And, since item 10, a stronger statement for the one operation that rewrites
rather than appends: a crash during compaction loses NOTHING. Compaction adds
no information, so the recovered state must equal the state before it exactly,
with no prefix weakening, at every boundary. `rename(2)` is the commit point
and it is atomic, so the only two reachable outcomes are the whole old log and
the whole new one. That equality is checked against a model dict rather than
against walkv's own reader, because a workload with deletes in it has no
prefix to check.

## Oracle

Ranked by how little the author controls them:

1. `dm-log-writes` replay to every block-level flush boundary, **not yet**,
   needs root. This is the real oracle and milestone 2 exists to reach it.
2. The filesystem as the kernel reports it: `test -f` after each crash, which
   is what says whether the compaction window was really entered and whether a
   temp file was leaked. Not negotiable with, and not written by this project.
3. `t/model.py`, an independent reader of the record format plus a model of
   the workload kept in a plain dict. Second implementation rather than
   outside authority, so it ranks below the kernel: what it buys is that
   recovery is no longer checked by walkv's own reader agreeing with walkv's
   own writer. It is strict where walkv is lenient, and refuses any log with a
   short or corrupt record.
4. `t/crash.sh`, process-level kill at every I/O boundary, including the
   boundary inside recovery itself. 704 scenarios.
5. ASan + UBSan over the recovery parser, which reads post-crash bytes, with
   `make overread` asserting that the sanitizer can still see an over-read
   there at all.
6. The monotonicity check, which catches ordering bugs the prefix check alone
   would pass.

## Non-goals

Concurrency and locking. Range scans. Transactions across multiple keys.
Networking. Anything resembling a real database's feature list, this exists to
be crashed, not to be used. Compaction was on this list until item 10, and it
came off it for one reason: it is the operation during which two copies of the
log exist at once, which is the crash window nothing else here reaches.

## Commit sequence

- [x] 00 WAL append with CRC, index, recovery that truncates at the first bad record
      files: walkv.c Makefile
      proves: `walkv db bulk 20 && walkv db verify-prefix 20` -> prefix 20
- [x] 01 crash injection hook (`WALKV_CRASH_AT`, `WALKV_TORN`)
      why: no way to test durability without the ability to die on command
- [x] 02 the harness: every boundary, both modes, plus monotonicity
      files: t/crash.sh
      proves: 219 scenarios, 0 failures
- [x] 03 fix: torn request at an fsync boundary must still crash
      why: half the torn scenarios were silently not crashing at all
- [x] 04 fix: truncate at the start of the bad record, not after the short read
      why: left a partial header for the next append to build on
- [x] 05 garbage-tail and bitflip scenarios
- [x] 06 ASan/UBSan run of the whole harness
- [x] 07 append-after-recovery pass: write a key after every crash point
      why: nothing ever wrote after a recovery, so a recovery that left the log
           subtly wrong was invisible. 83 -> 163 scenarios.
- [x] 08 mutation testing: WALKV_BUG plants a defect, make mutants asserts the
      outcome, including the two that are deliberately NOT caught
      proves: no-crc and truncate-cursor caught; accept-short masked by the CRC
              check; no-fsync invisible to any process-kill harness

### Milestone 1: make the store worth crashing

- [x] 07 batch commit: group N puts into one fsync, and prove the prefix
      invariant still holds at batch granularity, not record granularity
      why: this is where real stores get it wrong, and the harness should catch it
      done: `batch N B` fsyncs every B puts: 25 I/O boundaries instead of 40
      at N=20 B=4, asserted, because a "batching" that still synced every
      record would pass every other check here. The prefix property turns out
      to be unchanged (records still go out in order, so recovery still
      truncates to k0..kj-1); what changes is how much of that prefix is owed.
      So the acknowledgement became observable: `durable J` to stdout after
      every successful fsync, via write(2) because _exit discards a stdio
      buffer, and the harness requires the recovered prefix to cover the last J
      claimed. 163 -> 219 scenarios.
      And it found the ceiling again. WALKV_BUG=ack-before-sync prints the
      acknowledgement one instruction before the fsync that earns it: the
      textbook form of this bug, and the new check cannot see it, for exactly
      the reason no-fsync is invisible: by then the records really are in the
      file. It is in t/mutants.sh asserted as MISSED, so the new durability
      check cannot be mistaken for more than it is, and it will start failing
      the day item 12 lands.
- [x] 09 crash during recovery itself, recovery must be idempotent and
      re-runnable, a separate invariant from the prefix property
      files: walkv.c t/crash.sh t/mutants.sh
      proves: recovering a damaged log, dying at any boundary of that
              recovery, and recovering again reaches the same bytes as one
              uninterrupted recovery, compared against that uninterrupted
              recovery rather than against anything this harness decides.
              And the fixpoint half: recovering an already recovered log
              changes nothing. 219 -> 349 scenarios.
      found: recovery's ftruncate was an I/O boundary nobody had counted, so
              no crash had ever landed inside recovery. The pin that was
              meant to catch exactly that, TOTAL == 2N, agreed with the
              implementation because both came from the same picture of
              where I/O happens: a check written from the author's model of
              the code, not from an authority outside it. It is 2N + 1 now.
              Two planted defects, each caught by one half of the new pass
              and invisible to the other and to all 308 older scenarios:
              repair-tail mends the bad tail into a valid record before
              dropping it, so an interrupted recovery leaves a fabricated
              record behind, and recover-marker appends an audit record on
              every recovery, so recovery stops being a fixpoint.
              With one mutating syscall the real recovery is idempotent by
              construction, which is the honest result here: the matrix is
              what covers item 10, where compaction makes recovery
              multi-step.
- [x] 10 log compaction, then crash at every boundary *during* compaction
      why: compaction is the single most dangerous operation in a log store
      files: walkv.c t/crash.sh t/mutants.sh t/model.py Makefile
      done: `compact` writes the live set to DB.compact, fsyncs it, renames it
      over DB, fsyncs the directory. rename(2) is the commit point and it is
      atomic, so the only two reachable outcomes are the old log and the new
      one. 22 boundaries at N=20, crashed at every one in both modes, and then
      the recovery that follows each crash crashed at every one of ITS
      boundaries: 44 + 84 = 128 injected crashes, enumerated, not sampled.
      349 -> 704 scenarios.
      oracle: the kernel and an independent parser, because for the first time
      in this repo the old check was not good enough. verify-prefix reads the
      index recovery built, which is walkv agreeing with walkv, and with a
      deleted key in the workload it reports a GAP and is the wrong question
      anyway. So t/model.py parses the recovered log from the format comment
      and compares it against a dict built by replaying the operations the
      HARNESS asked for, and the invariant is equality rather than a prefix:
      compaction rewrites what is already durable, so a crash during it may
      lose nothing at all. The filesystem answers the other half, with
      `test -f` after each crash.
      proves: the window really was entered. 20 of the 22 boundaries left both
      logs on disk at once, the two that cannot being the opening recovery and
      the one after the rename, and both outcomes of the commit occurred,
      21 rolled back and 1 committed. A harness that never fires inside that
      window passes vacuously and is the defect to expect here.
      found: a buffer larger than its data, the eighth in this collection.
      recover() decoded every key into a `char key[MAX_KEY + 1]` -- 1025 bytes
      for a two-byte key -- so a planted read one past the key printed
      "3 keys" and nothing from either ASan or UBSan. With malloc(klen + 1)
      the identical read is reported. `make overread` now compiles that probe
      under -DWALKV_PROBE_OVERREAD and requires the sanitizer to see it, and
      `make test` runs it, so rounding the buffer up again turns the suite red
      instead of quietly turning the sanitizer off over the whole parser.
      mutants: three caught and one deliberately not, and the division between
      them is the argument that both oracles are load bearing.
      compact-inplace rewrites the log where it lies: 36 model disagreements
      per mode. compact-keep-tmp leaks the temp file, which the model CANNOT
      see because the log is perfectly correct, so all 120 of its failures
      come from `test -e`. compact-prefer-tmp promotes the uncommitted temp,
      which the filesystem cannot see because there is nothing left over, so
      all 72 come from the model. compact-sync-late commits before the fsync
      that earns it -- the canonical compaction bug, a lost database on real
      hardware -- and all 704 scenarios pass under it, for the same page-cache
      reason no-fsync is invisible. Its boundary count is kept identical on
      purpose so the matrix-size pin cannot take the credit.
      missing: the nested recovery loop caught nothing the single recovery
      missed. Recovery's two steps now (drop the stray temp, truncate the
      tail) touch two different files and so commute, which makes it
      idempotent by construction again. Written down rather than dressed up:
      the loop is where an ordering bug between them would show, and it is
      what makes "every boundary" literal.

### Milestone 2: the real oracle

- [ ] 11 `dm-log-writes` capture: loop device, dm target, run the workload,
      capture the full block-level write stream
      note: needs root and a loop device, so it runs on the host, not in a container
      BLOCKED, 19 October 2026. Probed rather than assumed: this is a podman
      container, `/dev/loop-control` and `/dev/mapper/control` are present and
      `losetup` and `dmsetup` are installed under `/sbin`, and `sudo -n id`
      does return uid 0. What is not available is permission to use any of it:
      the one command that would have mattered, creating the loop devices and
      the `log-writes` dm target, is refused by this session's command policy.
      So the capture cannot be made here, and items 12 and 13 cannot start,
      since both consume a log that 11 produces. Nothing partial was built
      against the guess: a replay for a log format with no log to replay would
      be the exact vacuous harness this project exists to argue against.
      what unblocks it: a session on the host with permission to run
      `losetup --show -f IMG` twice and
      `dmsetup create NAME --table "0 SECTORS log-writes DATADEV LOGDEV"`.
      The replay side needs no privilege and can be written in Python from
      the kernel's own `Documentation/admin-guide/device-mapper/log-writes.rst`
      rather than by building xfstests, which hard rule 5 and the no-foreign-
      build-scripts rule both point away from.
- [ ] 11a a non-root approximation, if 11 stays blocked: an `LD_PRELOAD` shim
      over `write`/`pwrite`/`fsync`/`ftruncate`/`rename`/`unlink`, capturing
      the stream at the libc boundary so walkv cannot be the thing reporting
      on walkv, and a replay that reconstructs the files as of each flush and
      DISCARDS the unflushed writes
      why: that is the one thing `_exit` cannot do, and it is what makes
           `no-fsync`, `ack-before-sync` and `compact-sync-late` all three
           invisible today. It is weaker than 11, because it still trusts the
           kernel to have done what it was told, but it moves the ceiling
           rather than describing it.
      note: not started. The honest cost is a mini-VFS in the replay, since
            compaction renames and unlinks, so the capture has to replay a
            namespace and not just a byte array. Worth it only if 11 cannot
            be unblocked; 11 is strictly better and much less code.
- [ ] 12 replay the captured log to every *flush* boundary, mount, recover,
      assert the invariants at each one
      why: this tests what the device really guaranteed, not what the process
      thought it did. Catches reordering that `_exit` cannot.
- [ ] 13 `dm-flakey` pass: drop writes in a window instead of truncating cleanly
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
  Item 10 answered part of this by accident: a workload with overwrites and
  deletes has no prefix at all, and the model-dict comparison is what replaces
  it. The same comparison is what item 15 will need, since a linearizability
  check is a statement about a history rather than about an ordering of keys.
- Whether 08's planted bug should be a build flag or a runtime env var. Runtime
  is easier to test but means shipping known-broken code in the binary.
