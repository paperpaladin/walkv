#!/bin/sh
# Mutation testing for the crash harness: can t/crash.sh actually fail?
#
# A harness nobody has watched fail buys confidence without earning it, and this
# one has already been silently broken once -- the torn-mode fsync boundary called
# the injection hook and discarded its return value, so half the matrix completed
# without crashing and reported a perfect prefix.
#
# So: plant a known defect via WALKV_BUG, run the whole matrix, and assert the
# result. Two of the five defects are expected to be CAUGHT. Three are expected
# to slip through, for reasons worth writing down --
# asserting that a defect is NOT caught is how the harness's ceiling stays honest
# instead of becoming folklore.
cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0

# expect <bug> <caught|missed> <why>
expect() {
  bug="$1"; want="$2"; why="$3"
  all=$(WALKV_BUG="$bug" ./t/crash.sh 2>&1)
  out=$(printf '%s' "$all" | tail -1)
  n=$(printf '%s' "$out" | sed -n 's/.*checked, \([0-9]*\) failed/\1/p')

  # `[ -n "$n" ] || n=0` turned "the harness never reached its summary" into
  # "zero scenarios failed", which the `missed` branch below reads as success.
  # The asymmetry gave it away: a broken harness is a correct FAIL for a
  # `caught` expectation and a false `ok` for all three `missed` ones. Proved
  # by adding a defect that makes `bulk` return early, so crash.sh bails at
  # "could not count I/O points" and prints no summary at all -- declared
  # `missed`, it scored "ok ... missed, as expected".
  #
  # The sanity gate further down only covers the undefected run, so it cannot
  # see a defect that breaks the harness itself.
  if [ -z "$n" ]; then
    fail=$((fail + 1))
    printf 'FAIL   %-16s the harness printed no summary, so there is no verdict\n' "$bug"
    printf '         last line was: %s\n' "$out"
    return
  fi

  if [ "$want" = caught ]; then
    if [ "$n" -gt 0 ]; then
      pass=$((pass + 1)); printf 'ok     %-16s caught (%s scenarios failed)\n' "$bug" "$n"
    else
      fail=$((fail + 1))
      printf 'FAIL   %-16s SHOULD be caught but the matrix passed clean\n' "$bug"
      printf '         the harness has lost the ability to detect this\n'
    fi
  else
    if [ "$n" = 0 ]; then
      pass=$((pass + 1)); printf 'ok     %-16s missed, as expected -- %s\n' "$bug" "$why"
    else
      # Not a failure of correctness, but the documentation is now wrong.
      fail=$((fail + 1))
      printf 'FAIL   %-16s now CAUGHT (%s failed) but documented as missed\n' "$bug" "$n"
      printf '         good news; update this file and the README ceiling note\n'
    fi
  fi
}

# Sanity first: with no defect planted the matrix must be clean, or every result
# below is meaningless.
clean=$(./t/crash.sh 2>&1 | tail -1)
n=$(printf '%s' "$clean" | sed -n 's/.*checked, \([0-9]*\) failed/\1/p')
if [ "$n" = 0 ]; then
  pass=$((pass + 1)); printf 'ok     %-16s %s\n' "(no defect)" "$clean"
else
  printf 'FAIL   the undefected matrix is not clean: %s\n' "$clean"
  printf '       nothing below can be trusted; fix that first\n'
  exit 1
fi

# --- caught ------------------------------------------------------------------

expect no-crc caught
# Skips CRC verification during recovery.
#
# The detector is the single `bitflip` scenario, not the torn-write pass this
# note used to name. A torn write here always leaves the tail short in the
# *body*, so `got < klen + payload` fires before any CRC is computed -- zero
# of the 40 torn boundaries ever reach a CRC comparison, measured by printing
# on every mismatch. WALKV_BUG=no-crc fails exactly one of the 219 scenarios,
# and it is `[bitflip] CORRUPT at k19`.
#
# What that means for coverage: CRC is exercised by 1 scenario out of 219. A
# full-length record with corrupt bytes -- what a real sector-granular torn
# write produces -- does not occur in the matrix at all.

expect truncate-cursor caught
# Truncates at the read cursor instead of the last good record boundary, leaving a
# partial header for the next append to build on. The original 83-scenario matrix
# passed clean under this defect: every scenario crashed, recovered and verified,
# and then stopped, so nothing ever wrote after a recovery. Adding the
# append-after-recovery pass is what made it visible, and it now fails 20.

# --- missed, deliberately ----------------------------------------------------

expect accept-short missed \
  "the CRC check masks it -- defense in depth, not a harness miss"
# Carries on past a short header by zero-padding it instead of stopping.
#
# This used to say the klen sanity check masks it, because "the padded klen
# reads as 0 and the existing klen == 0 check breaks the loop anyway". That is
# not what happens. The torn tail is always 8 or 9 bytes -- measured at all 40
# boundaries, never under 4 -- so klen, which is header bytes 4..7, is always
# fully read and never zero. The field that gets zero-padded is vlen.
#
# Removing the guards one at a time under WALKV_BUG=accept-short:
#
#   baseline                                219 checked, 0 failed
#   minus "klen == 0 ||"                     219 checked, 0 failed
#   minus that and the short-body guard      219 checked, 0 failed
#   minus those and the CRC check            219 checked, 21 failed
#
# So the CRC check is the one doing the masking -- the mechanism this harness
# exists to test, not an unrelated sanity check. That makes it a weaker
# "missed" than the old note claimed: the defect is caught by the feature
# under test rather than neutralised by a bystander.

expect no-fsync missed \
  "killing a process does not lose the page cache; only a device-level test can"
# THE CEILING OF THIS WHOLE PROJECT. Skipping fsync entirely changes nothing that
# _exit(99) can observe: the data is in the kernel's page cache, and the kernel
# survives the process. Durability against a real power loss is invisible to any
# process-kill harness, however thorough.
#
# That is what dm-log-writes is for -- capture the block-level write stream and
# replay the device to each flush boundary. It needs root and a loop device, so it
# runs on the host rather than in a container. PLAN.md milestone 2.
#
# Until then, this assertion is the honest statement of what 216 green scenarios
# do and do not prove.

expect ack-before-sync missed \
  "the same page-cache ceiling as no-fsync, reached from the other direction"
# Found while adding batch commit. The batched contract is "once a batch is
# acknowledged, every record in it survives", and this defect prints the
# acknowledgement BEFORE the fsync that earns it -- the textbook version of
# that bug, and the reason the acknowledgement is written to stdout at all.
#
# The new durability assertion in t/crash.sh requires the recovered prefix to
# cover the last acknowledged J, and it cannot see this. For exactly the reason
# no-fsync is invisible: the records really are in the file by then, because
# _exit does not discard the page cache, so a claim made one instruction too
# early is still true as far as any process-kill harness can tell.
#
# It is worth having anyway. It states, in a form that runs, that the batch
# durability check is bounded by the same ceiling as everything else here, and
# it will begin failing the day dm-log-writes lands -- which is the point at
# which this file gets updated rather than this defect fixed.

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
