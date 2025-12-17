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
[torn] final prefix 20/20

83 scenarios checked, 0 failed
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
2. Recovery truncated the log at the file offset *after* a short read rather
   than at the start of the bad record, which would have left a partial header
   in place for the next append to build on.

## Status

Works, and the invariants hold across all 83 scenarios, including under
`-fsanitize=address,undefined` (`make test-asan`). ASan reports leaks there
because the index is never freed -- see below.

Not implemented: compaction, so the log grows forever. No concurrency, so no
locking. No range scans or iteration. Values capped at 1MB, keys at 1KB.

### The ceiling on this harness

Killing the process tests the application's ordering, not the **device's**. A
real crash can reorder or lose writes the kernel already acknowledged, which
`_exit` cannot simulate. The real version of this uses `dm-log-writes` to
capture the block-level write stream and replay the device to every flush
boundary -- that needs root and a loop device, so it is the next milestone rather
than something that runs in a container. See `PLAN.md`.

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
