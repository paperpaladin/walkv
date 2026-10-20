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

# Every scratch path is per-run. It used to be a fixed t/db plus nine fixed
# t/*.tmp names, which puts this harness in the worst class there is: two
# concurrent runs feed each other their files, and the symptom is not an error
# but a page of plausible crash-consistency failures. That happened once, with
# make mutants in the background and make test in the foreground, and it
# produced 164 invented failures including "prefix went backwards" -- the one
# output this project would most want to believe.
T=t/w$$
DB=$T.db
trap 'rm -f "$T".* ' EXIT HUP INT TERM

# Run the thing that was built, not the thing lying around. This harness
# compiles nothing it tests, so invoked directly after an edit it reports a
# pass for the previous binary -- three mutations of a sibling repo were each
# recorded as surviving that way. make test depends on the binary, so the
# documented path is safe; this is for the undocumented one.
if [ "$WALKV" = ./walkv ] && [ walkv.c -nt ./walkv ]; then
  echo "walkv.c is newer than ./walkv: run make test, not t/crash.sh directly"
  exit 1
fi

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
    cp "$DB" "$T".dmg

    # The reference: one uninterrupted recovery of this damaged log. The same
    # run reports how many I/O boundaries a recovery has, which is how many
    # places the loop below has to kill it.
    cp "$T".dmg "$T".ref
    RT=$(WALKV_COUNT_IO=1 "$WALKV" "$T".ref recover 2>&1 >/dev/null | awk '/io_points/ {print $2}')
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
    cp "$T".ref "$T".again
    "$WALKV" "$T".again recover >/dev/null 2>&1
    checked=$((checked + 1))
    if ! cmp -s "$T".ref "$T".again; then
      printf 'FAIL [idem] crash_at=%-3s recovering an already recovered log changed it\n' "$i"
      fail=$((fail + 1))
    fi

    # Idempotent: crash the recovery at each of its own boundaries, recover
    # again, and demand the same bytes as the uninterrupted run.
    r=1
    while [ "$r" -le "$RT" ]; do
      cp "$T".dmg "$DB"
      WALKV_CRASH_AT="$r" "$WALKV" "$DB" recover >/dev/null 2>&1
      [ $? -eq 99 ] && crashed=$((crashed + 1))
      "$WALKV" "$DB" recover >/dev/null 2>&1
      checked=$((checked + 1))
      if ! cmp -s "$T".ref "$DB"; then
        printf 'FAIL [idem] crash_at=%-3s killed at recovery boundary %s, then\n' "$i" "$r"
        printf '     recovered again: %s bytes against the reference %s\n' \
               "$(wc -c < "$DB")" "$(wc -c < "$T".ref)"
        fail=$((fail + 1))
      fi
      r=$((r + 1))
    done
    i=$((i + 1))
  done
  rm -f "$T".dmg "$T".ref "$T".again

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
      WALKV_CRASH_AT="$i" WALKV_TORN=1 "$WALKV" "$DB" batch "$N" "$BATCH" >"$T".ack 2>/dev/null
    else
      WALKV_CRASH_AT="$i" "$WALKV" "$DB" batch "$N" "$BATCH" >"$T".ack 2>/dev/null
    fi

    # The highest J we told anyone was durable before dying. Empty means we
    # never acknowledged anything, so nothing is owed.
    ack=$(awk '/^durable /{j=$2} END{print j+0}' "$T".ack)

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
"$WALKV" "$DB" batch "$N" "$BATCH" >"$T".ack 2>/dev/null
acks=$(grep -c '^durable ' "$T".ack)
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
rm -f "$T".ack

# -------------------------------------------------------------- compaction
#
# Compaction rewrites the log as one record per live key, and it is the most
# dangerous thing a log store does, because for the length of it the old log
# and the new one BOTH EXIST and exactly one of them is the truth. Every
# scenario above has had one file to get right; these have two.
#
# Three things are different about this pass.
#
# The oracle is outside walkv. Every check up to here has been walkv's reader
# agreeing with walkv's writer: verify-prefix reads the index that recovery
# built. Here the log is parsed by t/model.py, a second implementation of the
# record format written from the layout comment in walkv.c, and compared
# against a dict that t/model.py builds by replaying the operations THIS SCRIPT
# ASKED FOR. Nothing walkv printed feeds that dict. t/model.py is also strict
# where walkv is deliberately lenient: it refuses a log with any short or
# corrupt record, where walkv stops at the first one, so a recovery that
# truncated nothing cannot be agreed with.
#
# The invariant is equality, not a prefix. Compaction adds no information: it
# rewrites what is already durable. So a crash during it may lose NOTHING, and
# the recovered state must equal the model exactly, at every boundary. That is
# a far more falsifiable claim than "some prefix survived", and it is the
# reason the workload can now include overwrites and deletes, which have no
# prefix to be checked against.
#
# And the window is asserted to have been reached. The interesting boundaries
# are the ones where both logs are on disk at once; a harness that never fires
# inside that window passes vacuously. So after each crash this asks the
# KERNEL, with test -f, whether both files are there, and requires the count to
# come out at every boundary but the two that cannot qualify.
PY=${PY:-python3}
LIVE=$((N - 2))                  # the workload deletes two of the N keys

# t/model.py is the only external authority in this pass, so a missing python3
# is a failure and not a skip: without it these scenarios would report success
# having compared nothing.
if ! command -v "$PY" >/dev/null 2>&1; then
  printf 'FAIL [compact] no %s: t/model.py is the only external oracle for\n' "$PY"
  printf '     this pass, so skipping it would leave the scenarios checking\n'
  printf '     nothing and reporting success\n'
  fail=$((fail + 1))
  CTOTAL=0
else

# The workload, written down once and handed to both sides. walkv executes it;
# t/model.py replays the same lines into a dict. Two `bulk` runs mean every key
# is written twice, so compaction has real work: 2N + 2 records down to N - 2.
rm -f "$DB" "$DB.compact"
cat > "$T".ops <<EOF
bulk $N
bulk $N
del k3
del k7
EOF
"$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
"$WALKV" "$DB" bulk "$N" >/dev/null 2>&1
"$WALKV" "$DB" del k3 >/dev/null 2>&1
"$WALKV" "$DB" del k7 >/dev/null 2>&1
cp "$DB" "$T".base

before=$($PY t/model.py records "$T".base 2>&1)
checked=$((checked + 1))
out=$($PY t/model.py check "$T".base "$T".ops 2>&1) || {
  printf 'FAIL [compact] the uncompacted log already disagrees with the model: %s\n' "$out"
  printf '     every scenario below compares against this, so fix it first\n'
  fail=$((fail + 1))
}

# Every scenario starts from the base log with a torn tail glued on. Recovery
# has two mutating syscalls now -- drop a stray temp, then truncate the tail --
# and without a tail to drop the second one has no work in this pass, so
# crashing at that boundary would be vacuous: the log is already clean and the
# recovery that follows has nothing to finish.
restore_base() {
  cp "$T".base "$DB"
  printf 'zzzzzzzzzzzzzzzzzzzz' >> "$DB"
  rm -f "$DB.compact"
}

# And the tail must really be a tail, i.e. something t/model.py refuses, or
# the paragraph above is wishful. model.py is strict where walkv is lenient
# exactly so this question has an answer.
restore_base
checked=$((checked + 1))
if out=$($PY t/model.py records "$DB" 2>&1); then
  printf 'FAIL [compact] the glued-on tail parses as a clean log (%s records),
' "$out"
  printf '     so recovery has nothing to truncate and its second boundary is
'
  printf '     vacuous in every scenario below
'
  fail=$((fail + 1))
fi

# How many I/O boundaries does a compaction have? Counted by the code under
# test, so pinned: 1 for the recovery that `compact` opens with, one per live
# record, one for the fsync of the new log, one for the rename that commits it,
# one for the directory fsync.
restore_base
CTOTAL=$(WALKV_COUNT_IO=1 "$WALKV" "$DB" compact 2>&1 >/dev/null | awk '/io_points/ {print $2}')
checked=$((checked + 1))
if [ "${CTOTAL:-0}" -ne $((LIVE + 4)) ]; then
  printf 'FAIL [compact] reports %s io points for %s live records, expected %s:\n' \
         "${CTOTAL:-0}" "$LIVE" "$((LIVE + 4))"
  printf '     a boundary was added or lost and the matrix is the wrong size\n'
  fail=$((fail + 1))
  CTOTAL=${CTOTAL:-0}
fi

# That counting run was a real compaction. Did it do anything? A "compaction"
# that rewrote every record would satisfy every assertion below.
after=$($PY t/model.py records "$DB" 2>&1)
checked=$((checked + 1))
if [ "$after" != "$LIVE" ] || [ "$before" -le "$after" ]; then
  printf 'FAIL [compact] %s records became %s, expected %s live out of %s:\n' \
         "$before" "$after" "$LIVE" "$before"
  printf '     compaction is not collapsing anything, so crashing it proves nothing\n'
  fail=$((fail + 1))
else
  printf '[compact] %s records -> %s live, %s I/O boundaries\n' "$before" "$after" "$CTOTAL"
fi
checked=$((checked + 1))
out=$($PY t/model.py check "$DB" "$T".ops 2>&1) || {
  printf 'FAIL [compact] a clean compaction changed the state: %s\n' "$out"
  fail=$((fail + 1))
}

fi

run_compact_pass() {
  mode="$1"
  both=0          # crashes that landed with the old and new log both on disk
  committed=0     # scenarios that recovered to the compacted log
  rolled=0        # scenarios that recovered to the original log
  rboundaries=0   # recovery boundaries offered by those post-crash states
  rcrashed=0      # ... and how many of them really killed the process
  i=1
  while [ "$i" -le "$CTOTAL" ]; do
    restore_base
    if [ "$mode" = torn ]; then
      WALKV_CRASH_AT="$i" WALKV_TORN=1 "$WALKV" "$DB" compact >/dev/null 2>&1
    else
      WALKV_CRASH_AT="$i" "$WALKV" "$DB" compact >/dev/null 2>&1
    fi

    # Filesystem state as the kernel reports it, before anything recovers.
    if [ -f "$DB" ] && [ -f "$DB.compact" ]; then both=$((both + 1)); fi

    # Snapshot the post-crash filesystem state, both files, before anything
    # recovers: the nested loop below replays recovery from exactly here.
    cp "$DB" "$T".cdmg
    if [ -f "$DB.compact" ]; then cp "$DB.compact" "$T".ctmp
    else rm -f "$T".ctmp; fi

    # Recover, and count recovery's own boundaries while doing it. Recovery is
    # two mutating syscalls now rather than one -- drop the stray temp, then
    # truncate the tail -- which is what compaction took away from the
    # "idempotent by construction" argument that item 09 could still make.
    RT=$(WALKV_COUNT_IO=1 "$WALKV" "$DB" recover 2>&1 >/dev/null | awk '/io_points/ {print $2}')
    cp "$DB" "$T".cref          # the uninterrupted recovery, the reference

    want_rt=1
    [ -f "$T".ctmp ] && want_rt=2
    checked=$((checked + 1))
    if [ "${RT:-0}" -ne "$want_rt" ]; then
      printf 'FAIL [compact-%s] crash_at=%-3s recovery reports %s boundaries,\n' \
             "$mode" "$i" "${RT:-0}"
      printf '     expected %s (the truncate, plus the unlink when a temp is\n' "$want_rt"
      printf '     present): the nested loop below is the wrong size\n'
      fail=$((fail + 1))
    fi
    rboundaries=$((rboundaries + ${RT:-0}))

    # A leftover temp file is not harmless. It is a disk leak, and the next
    # compaction's O_TRUNC is the only thing that would ever clear it. The log
    # is perfectly correct in that case, so this is the one check that sees it.
    checked=$((checked + 1))
    if [ -e "$DB.compact" ]; then
      printf 'FAIL [compact-%s] crash_at=%-3s recovery left %s behind\n' \
             "$mode" "$i" "$DB.compact"
      fail=$((fail + 1))
    fi

    # The model. Equality, not a prefix: compaction owes everything.
    checked=$((checked + 1))
    if out=$($PY t/model.py check "$DB" "$T".ops 2>&1); then
      n=${out#ok }; n=${n% records}
      if [ "$n" = "$LIVE" ]; then committed=$((committed + 1))
      else rolled=$((rolled + 1)); fi
    else
      printf 'FAIL [compact-%s] crash_at=%-3s %s\n' "$mode" "$i" "$out"
      fail=$((fail + 1))
    fi

    # And the recovered log must still be compactable. A crash during
    # compaction that leaves the store readable but no longer able to compact
    # has moved the damage one operation into the future.
    "$WALKV" "$DB" compact >/dev/null 2>&1
    checked=$((checked + 1))
    out=$($PY t/model.py check "$DB" "$T".ops 2>&1) || {
      printf 'FAIL [compact-%s] crash_at=%-3s a second, clean compaction of the\n' "$mode" "$i"
      printf '     recovered log got it wrong: %s\n' "$out"
      fail=$((fail + 1))
    }

    # And now crash the RECOVERY FROM this crash, at each of its own
    # boundaries, and demand the same bytes as the uninterrupted recovery
    # above. This is the pair of crashes that happens in the field: the
    # machine loses power during a compaction and loses it again while
    # coming back up. The reference is a value this script does not choose --
    # whatever one recovery of this exact pair of files produces -- and it
    # was already checked against the model two assertions ago.
    r=1
    while [ "$r" -le "${RT:-0}" ]; do
      cp "$T".cdmg "$DB"
      if [ -f "$T".ctmp ]; then cp "$T".ctmp "$DB.compact"
      else rm -f "$DB.compact"; fi
      WALKV_CRASH_AT="$r" "$WALKV" "$DB" recover >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 99 ] && rcrashed=$((rcrashed + 1))
      checked=$((checked + 1))
      if [ "$rc" -ne 99 ]; then
        printf 'FAIL [compact-%s] crash_at=%-3s recovery boundary %s exited %s,\n' \
               "$mode" "$i" "$r" "$rc"
        printf '     not 99: the injection did not fire inside this recovery, so\n'
        printf '     re-running it only compares two uninterrupted recoveries\n'
        fail=$((fail + 1))
      fi
      "$WALKV" "$DB" recover >/dev/null 2>&1
      checked=$((checked + 1))
      if ! cmp -s "$T".cref "$DB" || [ -e "$DB.compact" ]; then
        printf 'FAIL [compact-%s] crash_at=%-3s killed at recovery boundary %s,\n' \
               "$mode" "$i" "$r"
        printf '     then recovered again: %s bytes against the reference %s%s\n' \
               "$(wc -c < "$DB")" "$(wc -c < "$T".cref)" \
               "$([ -e "$DB.compact" ] && printf ', and a temp file left behind')"
        fail=$((fail + 1))
      fi
      r=$((r + 1))
    done
    i=$((i + 1))
  done

  # DID THE CRASH LAND IN THE DANGEROUS WINDOW? Two boundaries cannot: the
  # first, which is the recovery `compact` opens with and runs before the temp
  # file is created, and the last, which is after the rename has already
  # consumed the temp name. Every other one must, and an injection that never
  # fires makes this zero.
  checked=$((checked + 1))
  if [ "$both" -eq $((CTOTAL - 2)) ]; then
    printf '[compact-%s] %s of %s crashes left the old and new log on disk at once\n' \
           "$mode" "$both" "$CTOTAL"
  else
    printf 'FAIL [compact-%s] %s of %s crashes left both logs on disk, expected %s:\n' \
           "$mode" "$both" "$CTOTAL" "$((CTOTAL - 2))"
    printf '     the only boundaries that cannot are the opening recovery and\n'
    printf '     the one after the rename. If this is 0 the injection never\n'
    printf '     fired inside compaction and the whole pass is vacuous\n'
    fail=$((fail + 1))
  fi

  # Every recovery boundary must really have killed the process. Same exact
  # floor as the [idem] pass rather than the half the writer passes use: a
  # recovery that ran to completion and was then re-run is the fixpoint check
  # again in borrowed clothes, not a crash test.
  checked=$((checked + 1))
  if [ "$rcrashed" -eq "$rboundaries" ] && [ "$rboundaries" -gt "$CTOTAL" ]; then
    printf '[compact-%s] the recovery from each was killed at all %s of its own
' \
           "$mode" "$rboundaries"
    printf '[compact-%s] boundaries, re-run, and reached the same bytes
' "$mode"
  else
    printf 'FAIL [compact-%s] %s of %s recovery boundaries crashed, and %s
' \
           "$mode" "$rcrashed" "$rboundaries" "$rboundaries"
    printf '     boundaries over %s scenarios means the two-step recovery that
' "$CTOTAL"
    printf '     a stray temp file creates was never reached
'
    fail=$((fail + 1))
  fi

  # Both outcomes have to occur, or one half of the claim is untested. rename
  # is the commit point: crash before it and the state is the old log, crash
  # after it and the state is the new one, and the model says they are equal.
  checked=$((checked + 1))
  if [ "$committed" -gt 0 ] && [ "$rolled" -gt 0 ]; then
    printf '[compact-%s] %s rolled back, %s committed, model agreed with all %s\n' \
           "$mode" "$rolled" "$committed" "$CTOTAL"
  else
    printf 'FAIL [compact-%s] %s committed and %s rolled back: only one side of\n' \
           "$mode" "$committed" "$rolled"
    printf '     the rename was ever observed, so the commit point is untested\n'
    fail=$((fail + 1))
  fi
}

if [ "$CTOTAL" -gt 0 ]; then
  run_compact_pass lost
  run_compact_pass torn
fi
rm -f "$T".base "$T".ops "$T".cdmg "$T".ctmp "$T".cref "$DB.compact"

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
