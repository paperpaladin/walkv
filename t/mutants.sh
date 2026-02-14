#!/bin/sh
# Mutation testing for the crash harness: can t/crash.sh actually fail?
#
# A harness nobody has watched fail buys confidence without earning it, and this
# one has already been silently broken once -- the torn-mode fsync boundary called
# the injection hook and discarded its return value, so half the matrix completed
# without crashing and reported a perfect prefix.
#
# So: plant a known defect via WALKV_BUG, run the whole matrix, and assert the
# result. Two of the four defects are expected to be CAUGHT. Two are expected to
# slip through, for reasons that are different and both worth writing down --
# asserting that a defect is NOT caught is how the harness's ceiling stays honest
# instead of becoming folklore.
cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0

# expect <bug> <caught|missed> <why>
expect() {
  bug="$1"; want="$2"; why="$3"
  out=$(WALKV_BUG="$bug" ./t/crash.sh 2>&1 | tail -1)
  n=$(printf '%s' "$out" | sed -n 's/.*checked, \([0-9]*\) failed/\1/p')
  [ -n "$n" ] || n=0

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
# Skips CRC verification during recovery, so a torn record is replayed as whole.
# The torn-write pass produces exactly that, and the prefix check sees the result.

expect truncate-cursor caught
# Truncates at the read cursor instead of the last good record boundary, leaving a
# partial header for the next append to build on. The original 83-scenario matrix
# passed clean under this defect: every scenario crashed, recovered and verified,
# and then stopped, so nothing ever wrote after a recovery. Adding the
# append-after-recovery pass is what made it visible, and it now fails 20.

# --- missed, deliberately ----------------------------------------------------

expect accept-short missed \
  "the klen sanity check masks it -- defense in depth, not a harness miss"
# Carries on past a short header by zero-padding it instead of stopping. The
# padded klen reads as 0, and the existing "klen == 0 || klen > MAX_KEY" check
# breaks the loop anyway. The defect is neutralised by an unrelated guard, which
# is a different thing from the harness being unable to see it. Worth asserting so
# that removing the klen check does not silently remove this protection too.

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
# Until then, this assertion is the honest statement of what 163 green scenarios
# do and do not prove.

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
