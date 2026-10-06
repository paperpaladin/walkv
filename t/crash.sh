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
if [ -z "$TOTAL" ]; then
  echo "could not count I/O points -- is $WALKV built?"
  exit 1
fi
printf '%d puts -> %d I/O boundaries\n\n' "$N" "$TOTAL"

run_pass() {
  mode="$1"       # "lost" or "torn"
  prev=-1
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
}

run_pass lost
run_pass torn

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
