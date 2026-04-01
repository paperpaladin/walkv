# walkv

A write-ahead-log key-value store, built to be crashed.

The store itself is ordinary -- append a CRC'd record, `fsync`, update an index.
The project is `t/crash.sh`, which kills the process at **every** I/O boundary
and checks that what survives is always a valid prefix of what was
acknowledged.

```
$ make test
20 puts -> 40 I/O boundaries

[lost] final prefix 20/20
[lost] 39 of 40 scenarios lost records, so the injection fired
[torn] final prefix 20/20
[torn] 39 of 40 scenarios lost records, so the injection fired
[append] recovery followed by a write, at every boundary
[batch] B=4: 25 I/O boundaries against 40 unbatched
[batch-lost] final prefix 20/20, every acknowledgement honoured
[batch-torn] final prefix 20/20, every acknowledgement honoured
[batch] a clean run acknowledges 5 times for 20 puts

216 scenarios checked, 0 failed

$ make mutants           # can the harness actually fail?
ok     (no defect)      216 scenarios checked, 0 failed
ok     no-crc           caught (1 scenarios failed)
ok     truncate-cursor  caught (20 scenarios failed)
ok     accept-short     missed, as expected -- the klen sanity check masks it
ok     no-fsync         missed, as expected -- killing a process does not lose
                        the page cache; only a device-level test can

5 passed, 0 failed
```

## The invariant

The workload writes `k0, k1, ... kN-1` in order, fsyncing each one. Two
properties follow from that:

- **Durability** -- once `put k5` returns, k5 survives a crash.
- **Atomicity** -- a half-written record never appears as a whole one.

Together they mean the recovered state is exactly `k0..kj-1` for some `j`, and
**never has a hole in it**. A hole is a lost acknowledged write. That is the bug
class this harness exists to find, and it is invisible to ordinary unit tests --
the store passes every functional test either way.

The harness also checks **monotonicity**: crashing later can never lose a record
that crashing earlier kept. A dip there means an `fsync` is not ordering what it
claims to order.

## What gets injected

`WALKV_CRASH_AT=n` kills the process at the nth I/O boundary. `WALKV_TORN=1`
makes that kill land halfway through the `write` instead of before it, so the
log ends in a partial record that CRC has to catch.

Five scenario families, 83 cases at `N=20`:

| scenario | what it proves |
|---|---|
| crash before each write | a never-acknowledged write is absent, cleanly |
| crash before each fsync | an unflushed write does not create a hole |
| torn write at each boundary | CRC truncates a partial record instead of parsing it |
| garbage appended to a clean log | junk past the last good record is discarded |
| single flipped bit in the tail | corruption truncates, never silently corrupts a value |

## Writing the harness found two bugs

Both in the harness, not the store, which is the usual ratio:

1. In torn mode the `fsync` boundary called the injection hook but discarded its
   return value, so half the scenarios completed without crashing at all and
   reported a perfect prefix. A tear is meaningless at an `fsync`, so it now
   degrades to a plain crash.

   And for a long time afterwards **nothing asserted that the injection had
   fired.** The hook was fixed; the check that would have caught it was not
   added. A crash that does nothing produces a completed run, `prefix 20`,
   monotonicity trivially satisfied because 20 is never less than 20, and a
   final line reading `final prefix 20/20` -- byte for byte the healthy
   output. Measured with the hook forced to `return false`:

   ```
   without the assertion:  216 scenarios checked, 0 failed
   with    the assertion:  216 scenarios checked, 2 failed
   ```

   Each pass now reports how many of its scenarios lost records (39 of 40;
   only a crash at the very last I/O point keeps everything) and fails if
   fewer than half did. `TOTAL` is pinned to `2N` as well, because it is
   self-reported by the code under test -- so "every I/O boundary" meant
   "every boundary the implementation admits to", and a forgotten
   `io_point()` call would shrink the matrix silently.
2. Recovery truncated the log at the file offset *after* a short read rather
   than at the start of the bad record, which would have left a partial header
   in place for the next append to build on.

## Status

Works, and the invariants hold across all 83 scenarios, including under
`-fsanitize=address,undefined` (`make test-asan`). ASan reports leaks there
because the index is never freed -- see below.

### Batch commit

`walkv DB batch N B` puts `k0..k(N-1)` and `fsync`s every `B` of them, which is
what any store does once per-record durability becomes the bottleneck: with
`N=20, B=4` it is 25 I/O boundaries instead of 40.

Batching weakens the contract on purpose, from "once `put` returns, it survives"
to "once a batch is acknowledged, every record in it survives". The weaker claim
is still a claim, so it is made observable: `durable J` goes to stdout after
every successful `fsync`, written with `write(2)` rather than `printf`, because
the process is about to be killed at an arbitrary point and an acknowledgement
lost in a stdio buffer is one nobody can hold us to. The harness then crashes at
every boundary of a batched run and requires the recovered prefix to cover the
last `J` claimed.

The prefix property itself is unchanged, and that is worth saying rather than
assuming: records still go out in order, so recovery truncating at the first bad
one still leaves `k0..kj-1` with no hole. What batching changes is how much of
that prefix is *owed*, not its shape.

Not implemented: compaction, so the log grows forever. No concurrency, so no
locking. No range scans or iteration. Values capped at 1MB, keys at 1KB.

## Can the harness fail?

216 green scenarios mean nothing until you have watched the harness go red. So
`WALKV_BUG=<name>` plants a known defect and `make mutants` asserts the outcome.
Five defects, and the interesting part is that **three of them slip through, for
reasons that are not the same**:

| defect | result | why |
|---|---|---|
| `no-crc` | caught | a torn record replays as whole; the prefix check sees it |
| `truncate-cursor` | caught | **only after a new scenario was added** -- see below |
| `accept-short` | missed | the `klen` sanity check masks it: defense in depth, not a harness miss |
| `no-fsync` | missed | **the ceiling of the project** -- see below |
| `ack-before-sync` | missed | the same ceiling, reached from the other direction |

`truncate-cursor` is the one that justifies the whole exercise. It truncates at the
read cursor rather than the last good record boundary, leaving a partial header for
the next append to build on -- and **the original 83-scenario matrix passed clean
under it.** Every scenario crashed, recovered, verified, and then stopped. Nothing
ever wrote *after* a recovery, so a recovery that left the log subtly wrong was
invisible. Adding the append-after-recovery pass took the matrix from 83 to 163
scenarios and the defect now fails 20 of them.

Asserting that a defect is **not** caught matters as much. It keeps the ceiling
written down instead of becoming folklore, and it means removing the `klen` check
will not silently remove a protection nobody knew was load-bearing.

### The ceiling on this harness

Killing the process tests the application's ordering, not the **device's**. A
real crash can reorder or lose writes the kernel already acknowledged, which
`_exit` cannot simulate.

This is not a theoretical concern -- it is measured. `WALKV_BUG=no-fsync` removes
the `fsync` call **entirely** and all 216 scenarios still pass, because the data
sits in the kernel's page cache and the kernel survives the process. No
process-kill harness, however thorough, can see that.

`ack-before-sync` is the same ceiling found from the other side, while adding
batch commit. The batched contract is "once a batch is acknowledged, every
record in it survives", so the store now prints `durable J` after each `fsync`
and the harness requires the recovered prefix to cover the last `J` it saw.
That is a real durability check and it still cannot see an acknowledgement
printed one instruction *before* the `fsync` that earns it -- because by then
the records are genuinely in the file, and only the device knows the difference.
Asserting that it is missed is what stops the new check being mistaken for more
than it is.

The real version of this uses `dm-log-writes` to capture the block-level write
stream and replay the device to every flush boundary -- that needs root and a
loop device, so it is the next milestone rather than something that runs in a
container. See `PLAN.md`.

## Design notes

Two deliberate corners, both marked `shortcut:` in the source:

- **`crc32()` comes from zlib**, which was already a dependency. A hand-rolled
  CRC table is 15 lines of code that can be subtly wrong.
- **Nothing is freed.** A CLI process that exits after one command does not need
  to tear down its index, which is why `make test-asan` runs with
  `detect_leaks=0`. The interesting ASan finding would be an overflow in the
  recovery parser, and there are none.

## License

GPL-3.0-or-later. A tool, not a library -- a fork should stay open.
