CFLAGS = -std=c11 -g -O1 -Wall -Wextra -D_FORTIFY_SOURCE=2 -ffile-prefix-map=$(CURDIR)=.
LDLIBS = -lz

walkv: walkv.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

# The point of the project: crash at every I/O boundary, check what survives.
test: walkv
	@./t/crash.sh
	@$(MAKE) --no-print-directory overread

# Can the harness actually fail? Plants known defects and asserts which are
# caught -- and which are not, with the reason.
mutants: walkv
	@./t/mutants.sh

# Same, under ASan/UBSan, because recovery parses whatever bytes a crash left
# behind. Leak detection is off on purpose: this is a short-lived CLI that never
# frees its index, so every run "leaks" by design. We are looking for overflows
# and UB in the parser, not for a missing free before exit.
test-asan: walkv.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o walkv-asan walkv.c $(LDLIBS)
	@ASAN_OPTIONS=detect_leaks=0 WALKV=./walkv-asan ./t/crash.sh

# A buffer larger than its data turns the sanitizer off. recover() sizes its
# key buffer to klen + 1 for exactly that reason, and this asserts the
# consequence instead of trusting it: the same build with a deliberate read one
# byte past the key must be REPORTED. With a MAX_KEY-sized buffer the identical
# read is invisible to both sanitizers, so a clean ASan run over this parser
# would mean nothing.
overread: walkv.c walkv
	@$(CC) $(CFLAGS) -DWALKV_PROBE_OVERREAD -fsanitize=address,undefined \
	  -o walkv-probe walkv.c $(LDLIBS)
	@rm -f t/probe.tmp
	@./walkv t/probe.tmp bulk 3 >/dev/null
	@if ASAN_OPTIONS=detect_leaks=0 ./walkv-probe t/probe.tmp recover 2>&1 \
	    | grep -q 'runtime error\|Sanitizer'; then \
	  echo '[overread] the sanitizer sees a read one byte past the key'; \
	else \
	  echo 'FAIL [overread] a read one byte past the key is invisible: the key'; \
	  echo '     buffer is larger than its data, so the sanitizer is switched'; \
	  echo '     off over the whole recovery parser'; \
	  rm -f t/probe.tmp walkv-probe; exit 1; \
	fi
	@rm -f t/probe.tmp walkv-probe

clean:
	rm -f walkv walkv-asan walkv-probe t/probe.tmp t/w[0-9]*.*

.PHONY: test test-asan overread mutants clean
