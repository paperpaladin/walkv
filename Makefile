CFLAGS = -std=c11 -g -O1 -Wall -Wextra -D_FORTIFY_SOURCE=2 -ffile-prefix-map=$(CURDIR)=.
LDLIBS = -lz

walkv: walkv.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

# The point of the project: crash at every I/O boundary, check what survives.
test: walkv
	@./t/crash.sh

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

clean:
	rm -f walkv walkv-asan t/db t/*.tmp

.PHONY: test test-asan mutants clean
