#!/bin/sh
# Kill the store at every I/O boundary and check that what survives is always a
# valid prefix of what was acknowledged.
#
# Why a prefix: the workload writes k0, k1, ... kN-1 in order, fsyncing each.
# Durability says once `put k5` returns, k5 survives. Atomicity says a half
# written record never appears. Together those mean the recovered state is
# exactly k0..kj-1 for some j -- never with a hole in it. A hole is a lost
# acknowledged write, which is the bug class this harness exists to find.
#
# Two passes: crash BEFORE an I/O (lost write) and crash HALFWAY THROUGH one
# (torn record, caught by CRC).
cd "$(dirname "$0")/.." || exit 1

WALKV=${WALKV:-./walkv}
N=${N:-20}
DB=t/db

fail=0
checked=0

# How many I/O boundaries does a clean run of N puts have?
rm -f "$DB"
TOTAL=$(WALKV_COUNT_IO=1 "$WALKV" "$DB" bulk "$N" 2>&1 >/dev/null | awk '/io_points/ {print $2}')
# TOTAL comes from the implementation, so "every I/O boundary" means "every
# boundary the implementation admits to" -- a forgotten io_point() call
# shrinks the matrix silently and the suite still reports every scenario it
# ran as passing. A bulk of N puts is two boundaries each, the write and the
# fsync, plus one for the truncate that the recovery at open always performs,
# so the count is pinned rather than trusted.
if [ "${TOTAL:-0}" -ne $((2 * N + 1)) ]; then
  printf 'FAIL bulk reports %s io points for N=%s, expected %s: a boundary\n' \
         "${TOTAL:-0}" "$N" "$((2 * N + 1))"
  printf '     was added or lost, and the scenario matrix is the wrong size\n'
  fail=$((fail + 1))
fi
if [ -z "$TOTAL" ]; then
  echo "could not count I/O points -- is $WALKV built?"
  exit 1
fi
printf '%d puts -> %d I/O boundaries\n\n' "$N" "$TOTAL"

run_pass() {
  mode="$1"       # "lost" or "torn"
  prev=-1
  shrank=0        # scenarios where the crash actually cost us records
  i=1
  while [ "$i" -le "$TOTAL" ]; do
    rm -f "$DB"
    if [ "$mode" = torn ]; then
      WALKV_CRASH_AT="$i" WALKV_TORN=1 "$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
    else
      WALKV_CRASH_AT="$i" "$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
    fi

    # Recovery happens inside verify-prefix's db_open.
    out=$("$WALKV" "$DB" verify-prefix "$N" 2>&1)
    rc=$?
    checked=$((checked + 1))

    case "$out" in
      "prefix "*)
        got=${out#prefix }
        # Monotonicity: crashing later can never lose a record that crashing
        # earlier kept. A dip here means an fsync is not ordering what it claims.
        if [ "$got" -lt "$prev" ]; then
          printf 'FAIL [%s] crash_at=%-3s prefix went backwards: %s -> %s\n' \
                 "$mode" "$i" "$prev" "$got"
          fail=$((fail + 1))
        fi
        [ "$got" -lt "$N" ] && shrank=$((shrank + 1))
        prev=$got
        ;;
      *)
        printf 'FAIL [%s] crash_at=%-3s %s (rc=%s)\n' "$mode" "$i" "$out" "$rc"
        fail=$((fail + 1))
        ;;
    esac
    i=$((i + 1))
  done
  printf '[%s] final prefix %s/%s\n' "$mode" "$prev" "$N"

  # DID THE CRASH DO ANYTHING? Nothing here asked, and the answer has been
  # "no" before: README records that in torn mode the fsync boundary called
  # the injection hook and discarded its return value, so half the
  # scenarios completed without crashing at all and reported a perfect
  # prefix. The hook was fixed and no assertion was added.
  #
  # An injection that does nothing produces a completed run, "prefix 20",
  # monotonicity trivially satisfied because 20 is never less than 20, and
  # a final line reading "final prefix 20/20" -- byte for byte the healthy
  # output. Every scenario passes and the matrix measures nothing.
  #
  # Measured: 39 of the 40 boundaries lose records, and only a crash at the
  # very last io point keeps all N. Half is a floor with room under it, and
  # it is not satisfiable by an injection that never fires.
  if [ "$shrank" -gt $((TOTAL / 2)) ]; then
    printf '[%s] %s of %s scenarios lost records, so the injection fired\n' \
           "$mode" "$shrank" "$TOTAL"
  else
    printf 'FAIL [%s] only %s of %s scenarios lost any record: the crash\n' \
           "$mode" "$shrank" "$TOTAL"
    printf '     injection is not firing, and a matrix of completed runs\n'
    printf '     proves nothing about recovery\n'
    fail=$((fail + 1))
  fi
}

run_pass lost
run_pass torn

# ---------------------------------------------------------------- append after recovery
#
# Every scenario above crashes, recovers, and verifies -- and then stops. Nothing
# ever WRITES after a recovery, which means a recovery that leaves the log in a
# subtly wrong state is invisible: the damage only shows when the next append
# builds on it.
#
# Found by mutation testing. WALKV_BUG=truncate-cursor truncates at the read
# cursor rather than the last good record boundary, leaving a partial header in
# place. The whole 83-scenario matrix passed under that defect; a single append
# afterwards fails to read back.
run_append_pass() {
  i=1
  shrank=0        # scenarios where the crash actually cost us records
  while [ "$i" -le "$TOTAL" ]; do
    rm -f "$DB"
    WALKV_CRASH_AT="$i" WALKV_TORN=1 "$WALKV" "$DB" bulk "$N" >/dev/null 2>&1

    # Did the crash cost anything? run_pass has asked this since the fix that
    # section is named for, and this pass and the batch pass below never did
    # -- so a dead injection left 214 of the 216 scenarios passing. Measured
    # with io_point() neutralised: only [lost] and [torn] went red, and the
    # 80 append and 50 batch scenarios all reported success against a
    # completed run.
    _pre=$("$WALKV" "$DB" verify-prefix "$N" 2>&1)
    case "$_pre" in
      "prefix $N") : ;;
      *) shrank=$((shrank + 1)) ;;
    esac

    # Recover, then append a fresh key and read it back.
    "$WALKV" "$DB" put zz "survived" >/dev/null 2>&1
    got=$("$WALKV" "$DB" get zz 2>&1)
    checked=$((checked + 1))
    if [ "$got" != "survived" ]; then
      printf 'FAIL [append] crash_at=%-3s key written after recovery reads back as %s\n' "$i" "$got"
      fail=$((fail + 1))
    fi

    # And the pre-crash prefix must still be intact after that append.
    out=$("$WALKV" "$DB" verify-prefix "$N" 2>&1)
    checked=$((checked + 1))
    case "$out" in
      "prefix "*) : ;;
      *) printf 'FAIL [append] crash_at=%-3s prefix damaged by the later append: %s\n' "$i" "$out"
         fail=$((fail + 1)) ;;
    esac
    i=$((i + 1))
  done
  checked=$((checked + 1))
  if [ "$shrank" -gt $((TOTAL / 2)) ]; then
    printf '[append] recovery followed by a write, at every boundary\n'
    printf '[append] %s of %s scenarios lost records, so the injection fired\n' \
           "$shrank" "$TOTAL"
  else
    printf 'FAIL [append] only %s of %s scenarios lost any record: the crash\n' \
           "$shrank" "$TOTAL"
    printf '     injection is not firing, so appending to a log that never\n'
    printf '     lost anything proves nothing about recovery\n'
    fail=$((fail + 1))
  fi
}

run_append_pass

# ------------------------------------------------------ crash during recovery
#
# Everything above crashes the writer and then recovers once, uninterrupted.
# But recovery is itself I/O, and it is the one operation that runs after every
# crash, so it has to survive being crashed as well. A recovery that half
# finished and was then re-run is the normal case in the field: the machine
# that lost power once loses it again while coming back up.
#
# Two properties, both about recovery rather than about the prefix:
#
#   re-runnable: recovering an already recovered log changes nothing.
#   idempotent:  dying partway through a recovery and recovering again reaches
#                exactly the state one uninterrupted recovery reaches.
#
# What gets compared is the log file itself, byte for byte. The index is a pure
# function of those bytes, so two equal logs recover to the same store, and
# nothing else about the dead process survives to be compared.
#
# The reference is a clean recovery of the same damaged log, which is a value
# this harness does not choose: whatever one recovery does is the standard the
# interrupted ones are held to.
run_idem_pass() {
  crashed=0
  boundaries=0
  i=1
  while [ "$i" -le "$TOTAL" ]; do
    rm -f "$DB"
    WALKV_CRASH_AT="$i" WALKV_TORN=1 "$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
    cp "$DB" t/dmg.tmp

    # The reference: one uninterrupted recovery of this damaged log. The same
    # run reports how many I/O boundaries a recovery has, which is how many
    # places the loop below has to kill it.
    cp t/dmg.tmp t/ref.tmp
    RT=$(WALKV_COUNT_IO=1 "$WALKV" t/ref.tmp recover 2>&1 >/dev/null | awk '/io_points/ {print $2}')
    checked=$((checked + 1))
    if [ "${RT:-0}" -lt 1 ]; then
      printf 'FAIL [idem] crash_at=%-3s recovery reports %s I/O boundaries, so\n' "$i" "${RT:-0}"
      printf '     there is nothing to crash and this scenario checks nothing\n'
      fail=$((fail + 1))
      i=$((i + 1))
      continue
    fi
    boundaries=$((boundaries + RT))

    # Re-runnable: recovery has to be a fixpoint.
    cp t/ref.tmp t/again.tmp
    "$WALKV" t/again.tmp recover >/dev/null 2>&1
    checked=$((checked + 1))
    if ! cmp -s t/ref.tmp t/again.tmp; then
      printf 'FAIL [idem] crash_at=%-3s recovering an already recovered log changed it\n' "$i"
      fail=$((fail + 1))
    fi

    # Idempotent: crash the recovery at each of its own boundaries, recover
    # again, and demand the same bytes as the uninterrupted run.
    r=1
    while [ "$r" -le "$RT" ]; do
      cp t/dmg.tmp "$DB"
      WALKV_CRASH_AT="$r" "$WALKV" "$DB" recover >/dev/null 2>&1
      [ $? -eq 99 ] && crashed=$((crashed + 1))
      "$WALKV" "$DB" recover >/dev/null 2>&1
      checked=$((checked + 1))
      if ! cmp -s t/ref.tmp "$DB"; then
        printf 'FAIL [idem] crash_at=%-3s killed at recovery boundary %s, then\n' "$i" "$r"
        printf '     recovered again: %s bytes against the reference %s\n' \
               "$(wc -c < "$DB")" "$(wc -c < t/ref.tmp)"
        fail=$((fail + 1))
      fi
      r=$((r + 1))
    done
    i=$((i + 1))
  done
  rm -f t/dmg.tmp t/ref.tmp t/again.tmp

  # Did the injection fire? The other passes ask this with a floor of half,
  # because a crash at the last boundary legitimately costs nothing. Here it
  # is exact: every recovery boundary must really kill the process, since a
  # recovery that ran to completion and was then re-run is only the fixpoint
  # check again, wearing the clothes of a crash test.
  checked=$((checked + 1))
  if [ "$crashed" -eq "$boundaries" ]; then
    printf '[idem] recovery killed at all %s of its own boundaries, re-run, same bytes\n' \
           "$boundaries"
  else
    printf 'FAIL [idem] only %s of %s recovery boundaries actually crashed: the\n' \
           "$crashed" "$boundaries"
    printf '     injection is not firing inside recovery, and comparing two\n'
    printf '     uninterrupted recoveries proves nothing\n'
    fail=$((fail + 1))
  fi
}

run_idem_pass

# ------------------------------------------------------------- batch commit
#
# Grouping B puts into one fsync deliberately weakens the contract. Per record
# it was "once put returns, it survives". Batched it is "once a batch is
# acknowledged, every record in it survives" -- weaker, still a claim, and the
# one real stores get wrong.
#
# The prefix property is unchanged and still checked: records go out in order,
# so recovery truncating at the first bad one always leaves k0..kj-1. What is
# new is that the acknowledgement is now observable. `batch` writes "durable J"
# to stdout with write(2) after every successful fsync, unbuffered on purpose,
# because the process is about to be killed at an arbitrary point and an
# acknowledgement lost in a stdio buffer is one nobody can hold us to.
#
# So the assertion is the durability contract itself: the recovered prefix must
# cover the last J we claimed. Anything less is a lost acknowledged write.
BATCH=${BATCH:-4}

# The batched run has its own number of I/O boundaries, and it must be smaller
# -- otherwise "batching" is a no-op and every assertion below would pass for a
# store that still fsyncs every record.
rm -f "$DB"
BTOTAL=$(WALKV_COUNT_IO=1 "$WALKV" "$DB" batch "$N" "$BATCH" 2>&1 >/dev/null | awk '/io_points/ {print $2}')
checked=$((checked + 1))
if [ -z "$BTOTAL" ]; then
  printf 'FAIL [batch] could not count I/O points for a batched run\n'
  fail=$((fail + 1))
elif [ "$BTOTAL" -ge "$TOTAL" ]; then
  printf 'FAIL [batch] B=%s did not reduce I/O boundaries: %s vs %s unbatched\n' \
         "$BATCH" "$BTOTAL" "$TOTAL"
  fail=$((fail + 1))
else
  printf '[batch] B=%s: %d I/O boundaries against %d unbatched\n' "$BATCH" "$BTOTAL" "$TOTAL"
fi

run_batch_pass() {
  mode="$1"
  prev=-1
  shrank=0        # scenarios where the crash actually cost us records
  i=1
  while [ "$i" -le "$BTOTAL" ]; do
    rm -f "$DB"
    if [ "$mode" = torn ]; then
      WALKV_CRASH_AT="$i" WALKV_TORN=1 "$WALKV" "$DB" batch "$N" "$BATCH" >t/ack.tmp 2>/dev/null
    else
      WALKV_CRASH_AT="$i" "$WALKV" "$DB" batch "$N" "$BATCH" >t/ack.tmp 2>/dev/null
    fi

    # The highest J we told anyone was durable before dying. Empty means we
    # never acknowledged anything, so nothing is owed.
    ack=$(awk '/^durable /{j=$2} END{print j+0}' t/ack.tmp)

    out=$("$WALKV" "$DB" verify-prefix "$N" 2>&1)
    rc=$?
    checked=$((checked + 1))

    case "$out" in
      "prefix "*)
        got=${out#prefix }
        # Same floor as run_pass and the append pass: a crash that cost
        # nothing makes "every acknowledgement honoured" a statement about a
        # completed run.
        [ "$got" -lt "$N" ] && shrank=$((shrank + 1))
        if [ "$got" -lt "$ack" ]; then
          printf 'FAIL [batch-%s] crash_at=%-3s acknowledged %s durable, recovered %s\n' \
                 "$mode" "$i" "$ack" "$got"
          fail=$((fail + 1))
        fi
        if [ "$got" -lt "$prev" ]; then
          printf 'FAIL [batch-%s] crash_at=%-3s prefix went backwards: %s -> %s\n' \
                 "$mode" "$i" "$prev" "$got"
          fail=$((fail + 1))
        fi
        prev=$got
        ;;
      *)
        printf 'FAIL [batch-%s] crash_at=%-3s %s (rc=%s)\n' "$mode" "$i" "$out" "$rc"
        fail=$((fail + 1))
        ;;
    esac
    i=$((i + 1))
  done
  checked=$((checked + 1))
  if [ "$shrank" -gt $((BTOTAL / 2)) ]; then
    printf '[batch-%s] final prefix %s/%s, every acknowledgement honoured\n' "$mode" "$prev" "$N"
    printf '[batch-%s] %s of %s scenarios lost records, so the injection fired\n' \
           "$mode" "$shrank" "$BTOTAL"
  else
    printf 'FAIL [batch-%s] only %s of %s scenarios lost any record: the crash\n' \
           "$mode" "$shrank" "$BTOTAL"
    printf '     injection is not firing, so "every acknowledgement honoured"\n'
    printf '     is a statement about a run that completed\n'
    fail=$((fail + 1))
  fi
}

run_batch_pass lost
run_batch_pass torn

# An acknowledgement must actually have been made at some point, or every
# comparison above was against zero and proved nothing.
rm -f "$DB"
"$WALKV" "$DB" batch "$N" "$BATCH" >t/ack.tmp 2>/dev/null
acks=$(grep -c '^durable ' t/ack.tmp)
checked=$((checked + 1))
if [ "$acks" -lt 2 ]; then
  printf 'FAIL [batch] a clean run acknowledged %s times; the durability checks are vacuous\n' "$acks"
  fail=$((fail + 1))
else
  printf '[batch] a clean run acknowledges %s times for %s puts\n' "$acks" "$N"
fi
out=$("$WALKV" "$DB" verify-prefix "$N")
checked=$((checked + 1))
[ "$out" = "prefix $N" ] || { printf 'FAIL [batch clean] got %s\n' "$out"; fail=$((fail + 1)); }
rm -f t/ack.tmp

# A clean run must end with everything present.
rm -f "$DB"
"$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
out=$("$WALKV" "$DB" verify-prefix "$N")
checked=$((checked + 1))
if [ "$out" != "prefix $N" ]; then
  printf 'FAIL [clean] expected prefix %s, got %s\n' "$N" "$out"
  fail=$((fail + 1))
fi

# Garbage appended after a clean log must be discarded, not parsed.
printf 'zzzzzzzzzzzzzzzzzzzz' >> "$DB"
out=$("$WALKV" "$DB" verify-prefix "$N")
checked=$((checked + 1))
if [ "$out" != "prefix $N" ]; then
  printf 'FAIL [garbage tail] expected prefix %s, got %s\n' "$N" "$out"
  fail=$((fail + 1))
fi

# A single flipped bit inside the last record must truncate it, not corrupt it.
rm -f "$DB"
"$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
size=$(wc -c < "$DB")
dd if=/dev/zero of="$DB" bs=1 seek=$((size - 2)) count=1 conv=notrunc 2>/dev/null
out=$("$WALKV" "$DB" verify-prefix "$N")
checked=$((checked + 1))
case "$out" in
  "prefix "*) : ;;    # any prefix is fine; a GAP or CORRUPT is not
  *) printf 'FAIL [bitflip] %s\n' "$out"; fail=$((fail + 1)) ;;
esac

rm -f "$DB"
printf '\n%d scenarios checked, %d failed\n' "$checked" "$fail"
[ "$fail" = 0 ]
