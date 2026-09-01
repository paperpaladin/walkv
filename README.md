# walkv

A write-ahead-log key-value store, built to be crashed.

The store itself is ordinary: append a CRC'd record, `fsync`, update an index,
and compact the log when it has grown. What matters is `t/crash.sh`, which
kills the process at every I/O boundary and checks that what survives is always
a valid prefix of what was acknowledged -- and, during a compaction, that it is
not a prefix at all but exactly what was there before, checked against a model
`t/model.py` builds independently of anything walkv does.

```
$ make test
20 puts -> 41 I/O boundaries

[lost] final prefix 20/20
[lost] 40 of 41 scenarios lost records, so the injection fired
[torn] final prefix 20/20
[torn] 40 of 41 scenarios lost records, so the injection fired
[append] recovery followed by a write, at every boundary
[append] 40 of 41 scenarios lost records, so the injection fired
[idem] recovery killed at all 41 of its own boundaries, re-run, same bytes
[batch] B=4: 26 I/O boundaries against 41 unbatched
[batch-lost] final prefix 20/20, every acknowledgement honoured
[batch-lost] 25 of 26 scenarios lost records, so the injection fired
[batch-torn] final prefix 20/20, every acknowledgement honoured
[batch-torn] 25 of 26 scenarios lost records, so the injection fired
[batch] a clean run acknowledges 5 times for 20 puts
[compact] 42 records -> 18 live, 22 I/O boundaries
[compact-lost] 20 of 22 crashes left the old and new log on disk at once
[compact-lost] the recovery from each was killed at all 42 of its own
[compact-lost] boundaries, re-run, and reached the same bytes
[compact-lost] 21 rolled back, 1 committed, model agreed with all 22
[compact-torn] 20 of 22 crashes left the old and new log on disk at once
[compact-torn] the recovery from each was killed at all 42 of its own
[compact-torn] boundaries, re-run, and reached the same bytes
[compact-torn] 21 rolled back, 1 committed, model agreed with all 22

704 scenarios checked, 0 failed
[overread] the sanitizer sees a read one byte past the key

$ make mutants           # can the harness actually fail?
ok     (no defect)        704 scenarios checked, 0 failed
ok     no-crc             caught (1 scenarios failed)
ok     truncate-cursor    caught (64 scenarios failed)
ok     repair-tail        caught (89 scenarios failed)
ok     recover-marker     caught (139 scenarios failed)
ok     compact-inplace    caught (76 scenarios failed)
ok     compact-keep-tmp   caught (120 scenarios failed)
ok     compact-prefer-tmp caught (72 scenarios failed)
ok     accept-short       missed, as expected -- the CRC check masks it -- defense in depth, not a harness miss
ok     no-fsync           missed, as expected -- killing a process does not lose the page cache; only a device-level test can
ok     ack-before-sync    missed, as expected -- the same page-cache ceiling as no-fsync, reached from the other direction
ok     compact-sync-late  missed, as expected -- the rename is in the page cache too, so committing before the fsync looks identical

12 passed, 0 failed
```

## The invariant

The workload writes `k0, k1, ... kN-1` in order, fsyncing each one. Two
properties follow from that:

- Durability: once `put k5` returns, k5 survives a crash.
- Atomicity: a half-written record never appears as a whole one.

Together they mean the recovered state is exactly `k0..kj-1` for some `j`, and
never has a hole in it. A hole is a lost acknowledged write. That is the bug
class this harness exists to find, and it is invisible to ordinary unit tests:
the store passes every functional test either way.

The harness also checks monotonicity: crashing later can never lose a record
that crashing earlier kept. A dip there means an `fsync` is not ordering what it
claims to order.

## What gets injected

`WALKV_CRASH_AT=n` kills the process at the nth I/O boundary. `WALKV_TORN=1`
makes that kill land halfway through the `write` instead of before it, so the
log ends in a partial record that CRC has to catch.

704 cases at `N=20`. The table said "Five scenario families" and listed the
five below. Append, batch, recovery and compaction passes were added later and
never reached it:

| scenario | what it proves |
|---|---|
| crash before each write | a never-acknowledged write is absent, cleanly |
| crash before each fsync | an unflushed write does not create a hole |
| torn write at each boundary | a partial record is truncated, not parsed, by the short-body guard, since the tail is always short in the body and never reaches CRC |
| garbage appended to a clean log | junk past the last good record is discarded |
| single flipped bit in the tail | corruption truncates, never silently corrupts a value |
| recovery followed by an append, at every boundary | a recovered log is writable, not just readable |
| the same crash and torn passes with batching on | an acknowledgement is honoured even when the write behind it was deferred |
| recovery re-run on a log it already recovered | recovery is a fixpoint, so coming back up twice is not worse than once |
| recovery killed at its own I/O boundary, then re-run | an interrupted recovery reaches the same bytes as an uninterrupted one |
| a clean batched run | the acknowledgements are not vacuously zero |
| compaction killed at each of its 22 boundaries, both modes | the state after a crash during compaction equals the state before it, checked against a model this code did not build |
| and the recovery from each of those killed at each of ITS boundaries | two crashes in a row, which is the field's normal case, over a recovery that compaction made two steps long |
| the filesystem after each, as `test -e` reports it | no leftover `DB.compact`, and the dangerous window really was entered |
| a one-past-the-end read of the key buffer | the sanitizer can still see over-reads in the recovery parser at all |

## Writing the harness found two bugs

Both in the harness, not the store, the usual ratio:

1. In torn mode the `fsync` boundary called the injection hook but discarded its
   return value, so half the scenarios completed without crashing at all and
   reported a perfect prefix. A tear is meaningless at an `fsync`, so it now
   degrades to a plain crash.

   And for a long time afterwards **nothing asserted that the injection had
   fired.** The hook was fixed. The check that would have caught it was not
   added. A crash that does nothing produces a completed run, `prefix 20`,
   monotonicity trivially satisfied because 20 is never less than 20, and a
   final line reading `final prefix 20/20`, byte for byte the healthy
   output. Measured with the hook forced to `return false`:

   ```
   without the assertion:  349 scenarios checked, 0 failed
   with    the assertion:  349 scenarios checked, 6 failed
   ```

   It was 2 failed when only the `lost` and `torn` passes carried the
   assertion. The append pass and both batch passes did not, so a dead
   injection still left 214 of the 216 scenarios reporting success. That fix had landed in one pass out of four. Every pass reports now,
   and the measurement was repeated after compaction landed: a hook forced to
   `return false` fails **56 of the 704** scenarios, across all eight passes,
   and the matrix shrinks to 624 because an uncrashed compaction leaves its
   recovery one boundary instead of two.

   Each pass reports how many of its scenarios lost records (40 of 41 for the
   unbatched passes, 25 of 26 for the batched ones; only a crash at the very
   last I/O point keeps everything) and fails if fewer than half did. The
   recovery pass sets that floor at all of them rather than half, since a
   recovery that was never killed is only the fixpoint check again in
   borrowed clothes. `TOTAL` is pinned to `2N + 1` as well, because it is
   self-reported by the code under test, so "every I/O boundary" meant
   "every boundary the implementation admits to", and a forgotten
   `io_point()` call would shrink the matrix silently.
2. Recovery truncated the log at the file offset *after* a short read rather
   than at the start of the bad record, which would have left a partial header
   in place for the next append to build on.

## Status

Works, and the invariants hold across all 704 scenarios, including under
`-fsanitize=address,undefined` (`make test-asan`). ASan reports leaks there
because the index is never freed, see below.

### Batch commit

`walkv DB batch N B` puts `k0..k(N-1)` and `fsync`s every `B` of them, which is
what any store does once per-record durability becomes the bottleneck: with
`N=20, B=4` it is 26 I/O boundaries instead of 41.

Batching weakens the contract on purpose, from "once `put` returns, it survives"
to "once a batch is acknowledged, every record in it survives". The weaker claim
is still a claim, so it is made observable: `durable J` goes to stdout after
every successful `fsync`, written with `write(2)`, not `printf`, because
the process is about to be killed at an arbitrary point and an acknowledgement
lost in a stdio buffer is one nobody can hold us to. It then crashes at every boundary of a batched run and requires the recovered prefix to cover the
last `J` claimed.

The prefix property itself is unchanged, and that is worth stating explicitly: records still go out in order, so recovery truncating at the first bad
one still leaves `k0..kj-1` with no hole. What batching changes is how much of
that prefix is *owed*, not its shape.

Not implemented: no concurrency, so no locking. No range scans or iteration.
Compaction rewrites the whole log rather than merging levels, and it holds the
live set in memory while it does, so it is O(live set) in RAM. Values capped at
1MB, keys at 1KB.

### Crash during recovery

Every pass above crashes the writer and then recovers once, uninterrupted. In
the field that is the lucky case: the machine that lost power once tends to
lose it again while coming back up, so recovery has to survive being crashed
too. Two properties, neither of them the prefix invariant:

- Re-runnable. Recovering a log that has already been recovered changes
  nothing, so recovery is a fixpoint.
- Idempotent. Dying partway through a recovery and recovering again reaches
  exactly the state one uninterrupted recovery reaches.

What gets compared is the log file, byte for byte, against a reference the
harness does not choose: a clean recovery of the same damaged log. The index
is a pure function of those bytes, so equal logs recover to equal stores, and
nothing else about the dead process survives to be compared.

Recovery now admits to an I/O boundary of its own, the `ftruncate` that drops
the bad tail, which is the only thing recovery makes durable. That boundary
had never been counted. `TOTAL` was pinned to `2N`, a number worked out from
the writer's two syscalls per put, and it agreed with the implementation
because both were built from the same picture of where I/O happens. So the
harness crashed at every boundary in that picture and the one inside recovery
was outside it. The pin is `2N + 1` now and the matrix is 41 points wide
rather than 40.

With one mutating syscall, recovery is idempotent by construction: the only
states a crash can leave are the log before the truncate and the log after it,
and recovery maps both to the same place. That is a real answer rather than a
hollow one, and the pass earns its place by failing for a recovery that does
more than one thing: `WALKV_BUG=repair-tail` mends the bad tail into a well
formed record before deciding to drop it, which fails 41 scenarios here and
not one of the 308 that existed before. Compaction, next in `PLAN.md`, is the
operation that makes multi-step recovery real.

### Compaction

`walkv DB compact` rewrites the log as one record per live key: `k0..k19`
written twice plus two deletes is 42 records, and compaction makes it 18. The
log grows forever without it, because twenty overwrites of one key are twenty
records and a delete adds a record rather than removing one.

It is also the single most dangerous operation a log store performs, and the
reason is structural: for the length of it **both logs exist and exactly one of
them is the truth.**

```
1. write every live record into DB.compact      one boundary each
2. fsync it                                     one boundary
3. rename(DB.compact, DB)                       one boundary  <- the commit
4. fsync the directory                          one boundary
```

`rename(2)` is the commit point and it is atomic, so there is no instant at
which `DB` is a partially written log. Crash before step 3 and the old log is
untouched with a temp file to sweep up; crash after it and the new log is in
place. There is no third outcome. 22 boundaries at `N=20`, crashed at every one
of them in both modes, and then the recovery that follows each crash is itself
crashed at every one of **its** boundaries: 44 plus 84, 128 injected crashes,
enumerated rather than sampled.

Three things are different about this pass, and each of them is there because
the obvious version of it would have proved less.

**The oracle is outside walkv.** Every check before this one was walkv's reader
agreeing with walkv's writer: `verify-prefix` reads the index that recovery
built. Here the recovered log is parsed by `t/model.py`, a second
implementation of the record format written from the layout comment in
`walkv.c`, and compared against a dict `t/model.py` builds by replaying the
operations *the harness asked for*. Nothing walkv printed feeds that dict.
`t/model.py` is also strict where walkv is deliberately lenient: walkv stops at
the first short or corrupt record, because that is how a torn tail is made
safe, and the oracle refuses such a log outright, because after recovery has
run there must be no such tail left. A lenient oracle would have agreed with a
recovery that truncated nothing.

**The invariant is equality, not a prefix.** Compaction adds no information, it
rewrites what is already durable, so a crash during it may lose *nothing*. The
recovered state must equal the model exactly at every boundary. That is far
more falsifiable than "some prefix survived", and it is what lets the workload
include overwrites and deletes, which have no prefix to check against: with
`k3` deleted, `verify-prefix` reports a GAP and is simply the wrong question.

**The window is asserted to have been entered.** A crash-injection harness that
never fires inside the compaction window passes vacuously, which is exactly the
defect to expect here. So after each crash the harness asks the *kernel*, with
`test -f`, whether both logs are on disk, and requires the count to come out at
20 of 22 -- every boundary but the opening recovery, which runs before the temp
file exists, and the one after the rename, which has consumed it. It also
requires both outcomes of the commit to have occurred: 21 rolled back and 1
committed. A dead injection makes the first number 0 and the second 22.

Compaction also made recovery **two** mutating syscalls rather than one: drop a
stray `DB.compact`, then truncate the tail. The argument item 09 could still
make, that recovery is idempotent by construction because it has one mutating
syscall, is gone. So every scenario here starts from the base log with a torn
tail glued on, or the truncate step would have no work and crashing at that
boundary would be vacuous; and the harness asserts that the glued-on tail is
something the independent parser *refuses*, rather than assuming it.

What the nested recovery loop did NOT do is catch a defect the single recovery
missed. All four planted compaction defects are caught before it runs. The
honest reading is that recovery's two steps touch two different files and so
commute, which makes it idempotent by construction again; the loop is where an
ordering bug between them would show, and it is what makes "every boundary"
literally rather than approximately true.

## Can the harness fail?

704 green scenarios mean nothing until you have watched the harness go red. So
`WALKV_BUG=<name>` plants a known defect and `make mutants` asserts the outcome.
Eleven defects, and the interesting part is that **four of them slip through,
for reasons that are not the same**:

| defect | result | why |
|---|---|---|
| `no-crc` | caught | by the single `bitflip` scenario, not by the torn pass: 0 of 41 torn boundaries reach a CRC comparison, so CRC is exercised by 1 scenario of 704 |
| `truncate-cursor` | caught | **only after a new scenario was added**, see below |
| `repair-tail` | caught | by the crash-during-recovery pass and nothing else: all 308 older scenarios pass clean under it |
| `recover-marker` | caught | by the re-run half of that pass and nothing else, which is how both halves are shown to be load bearing |
| `compact-inplace` | caught | rewrites the log where it lies instead of renaming a new one into place: 36 model disagreements per mode, one per record-write boundary |
| `compact-keep-tmp` | caught | **by the filesystem and nothing else**: the log is correct, so the model sees zero disagreements across all 704, and 60 failures per mode come from `test -e` finding the leaked temp file |
| `compact-prefer-tmp` | caught | the mirror of it: promotes the uncommitted temp, so 36 failures per mode come from the model and none from the filesystem. Correct at the two boundaries where the temp happens to be complete, which is how this survives a harness that samples |
| `compact-sync-late` | missed | commits before the fsync that earns it, the canonical compaction bug. Same ceiling as `no-fsync`, see below |
| `accept-short` | missed | the **CRC** check masks it: the torn tail is always 8 or 9 bytes, so `klen` is fully read and the zero-padded field is `vlen`. Measured by removing each guard in turn, only removing the CRC check makes the defect visible (21 failures) |
| `no-fsync` | missed | **the ceiling of the project**, see below |
| `ack-before-sync` | missed | the same ceiling, reached from the other direction |

`truncate-cursor` is the one that justifies the whole exercise. It truncates at the
read cursor, not the last good record boundary, leaving a partial header for
the next append to build on, and **the original 83-scenario matrix passed clean
under it.** Every scenario crashed, recovered, verified, and then stopped. Nothing
ever wrote *after* a recovery, so a recovery that left the log subtly wrong was
invisible. Adding the append-after-recovery pass took the matrix from 83 to 163
scenarios and the defect now fails 20 of them.

Asserting that a defect is not caught matters as much. It keeps the ceiling
written down instead of becoming folklore, and it means removing the `klen` check
will not silently remove a protection nobody knew was load-bearing.

### The ceiling on this harness

Killing the process tests the application's ordering, not the device's. A
real crash can reorder or lose writes the kernel already acknowledged, which
`_exit` cannot simulate.

This is not a theoretical concern. It is measured. `WALKV_BUG=no-fsync` removes
the `fsync` call entirely and all 704 scenarios still pass, because the data
sits in the kernel's page cache and the kernel survives the process. No
process-kill harness, however thorough, can see that.

`ack-before-sync` is the same ceiling found from the other side, while adding
batch commit. The batched contract is "once a batch is acknowledged, every
record in it survives", so the store now prints `durable J` after each `fsync`
and the harness requires the recovered prefix to cover the last `J` it saw.
That is a real durability check and it still cannot see an acknowledgement
printed one instruction *before* the `fsync` that earns it, because by then
the records are genuinely in the file, and only the device knows the difference.
Asserting that it is missed is what stops the new check being mistaken for more
than it is.

`compact-sync-late` is the third sighting, and the worst of the three if it
ever shipped: it renames the new log into place and fsyncs it afterwards, so on
a real device the directory entry can reach the platter while the file's bytes
have not, and the database is gone. All 704 scenarios pass under it. Its
boundary count is deliberately left identical to the correct version -- the
`io_point()` calls stay put and only the `fsync` syscall moves -- so it cannot
be "caught" by the matrix-size pin or by the both-logs-on-disk count and then
credited to a durability check that noticed nothing.

The real version of this uses `dm-log-writes` to capture the block-level write
stream and replay the device to every flush boundary, that needs root and a
loop device, so it is the next milestone instead of something that runs in a
container. See `PLAN.md`.

## Design notes

Two deliberate corners, both marked `shortcut:` in the source:

- `crc32()` comes from zlib, which was already a dependency. A hand-rolled
  CRC table is 15 lines of code that can be subtly wrong.
- Nothing is freed. A CLI process that exits after one command does not need
  to tear down its index, so `make test-asan` runs with
  `detect_leaks=0`. The interesting ASan finding would be an overflow in the
  recovery parser, and there are none.

And one thing that was wrong and is not a corner. `recover()` decoded each key
into a `char key[MAX_KEY + 1]`, a 1025-byte buffer holding a two-byte key, and
**a buffer larger than its data turns the sanitizer off.** Measured, not
reasoned about: with the fixed-size buffer, a planted read at `key[klen + 1]`
produces `3 keys` and not one word from either ASan or UBSan, because the read
lands well inside a live object. With `malloc(klen + 1)` the identical read is
reported. Every clean ASan run this project had reported over its recovery
parser was clean over an area smaller than it looked.

So the trimming is checked rather than trusted. `make overread` builds the same
source with `-DWALKV_PROBE_OVERREAD`, which compiles exactly that one-byte
over-read, and requires the sanitizer to say so; `make test` runs it, and it
goes red if the buffer is ever rounded up again.

## License

GPL-3.0-or-later. A tool, not a library, a fork should stay open.
