// walkv -- a write-ahead-log key-value store, built to be crashed.
//
// The store is ordinary. The point of this project is t/crash.sh, which kills
// the process at every single I/O boundary and checks that what survives is
// always a valid prefix of what was acknowledged.
//
// WAL record layout, little-endian:
//
//   u32 crc      CRC-32 of every byte after this field
//   u32 klen
//   u32 vlen     0xFFFFFFFF marks a tombstone (delete)
//   u8  key[klen]
//   u8  val[vlen]
//
// Recovery replays records in order and stops at the first one that is short or
// fails CRC. That truncation point is what makes a torn tail safe.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>     // shortcut: crc32() is already here, don't hand-roll a table

#define TOMBSTONE 0xFFFFFFFFu
#define MAX_KEY   1024
#define MAX_VAL   (1 << 20)
#define NBUCKETS  1024

// ------------------------------------------------------- crash injection

// A test hook, not a feature. WALKV_CRASH_AT=n kills the process at the nth
// I/O boundary; WALKV_TORN=1 makes that kill land halfway through the write
// instead of before it, which is what produces a torn record.
static long crash_at = -1;
static bool torn_mode = false;
static long io_points = 0;
static bool counting = false;

// WALKV_BUG=<name> plants a deliberate defect. The point is not to ship bugs: it
// is to prove the crash harness can FAIL. A harness nobody has watched fail buys
// confidence without earning it, and this one has already been silently broken
// once (the torn-mode fsync boundary discarded its hook's return value).
//
// t/mutants.sh runs the whole matrix under each of these and asserts it goes RED.
// One of them -- no-fsync -- is expected to go UNDETECTED, and that is the
// honest demonstration of this harness's ceiling. See the note there.
static const char *bug;
static bool bug_is(const char *name) { return bug && !strcmp(bug, name); }

static void io_hook_init(void) {
  bug = getenv("WALKV_BUG");
  char *s = getenv("WALKV_CRASH_AT");
  if (s) crash_at = strtol(s, NULL, 10);
  torn_mode = getenv("WALKV_TORN") != NULL;
  counting = getenv("WALKV_COUNT_IO") != NULL;
}

// Returns true if the caller should write only half its buffer and then die.
static bool io_point(void) {
  io_points++;
  if (crash_at < 0 || io_points != crash_at) return false;
  if (torn_mode) return true;
  _exit(99);                 // no atexit, no stdio flush: a real crash
}

// ------------------------------------------------------------ the index

typedef struct Entry Entry;
struct Entry {
  Entry *next;
  char *key;
  uint8_t *val;
  uint32_t vlen;
};

typedef struct {
  int fd;
  const char *path;          // compaction needs to name its sibling temp file
  Entry *buckets[NBUCKETS];
} DB;

static unsigned hash(const char *s) {
  unsigned h = 2166136261u;                    // FNV-1a
  while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
  return h % NBUCKETS;
}

static Entry **find_slot(DB *db, const char *key) {
  Entry **p = &db->buckets[hash(key)];
  while (*p && strcmp((*p)->key, key)) p = &(*p)->next;
  return p;
}

static void index_put(DB *db, const char *key, const uint8_t *val, uint32_t vlen) {
  Entry **slot = find_slot(db, key);
  if (*slot) {
    free((*slot)->val);
  } else {
    *slot = calloc(1, sizeof(Entry));
    (*slot)->key = strdup(key);
  }
  (*slot)->val = malloc(vlen ? vlen : 1);
  memcpy((*slot)->val, val, vlen);
  (*slot)->vlen = vlen;
}

static void index_del(DB *db, const char *key) {
  Entry **slot = find_slot(db, key);
  if (!*slot) return;
  Entry *dead = *slot;
  *slot = dead->next;
  free(dead->key); free(dead->val); free(dead);
}

// ------------------------------------------------------------- durability

static bool write_all(int fd, const void *buf, size_t n, bool allow_torn) {
  size_t to_write = n;
  if (allow_torn && n > 1) to_write = n / 2;   // the torn write

  const uint8_t *p = buf;
  size_t left = to_write;
  while (left) {
    ssize_t w = write(fd, p, left);
    if (w < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += w; left -= w;
  }
  if (allow_torn) {
    // Make the half-record durable so recovery actually has to cope with it.
    fsync(fd);
    _exit(99);
  }
  return true;
}

// Appends one record without making it durable. The caller owes a wal_sync()
// before it may tell anyone the write happened.
static bool wal_write(int fd, const char *key, const uint8_t *val, uint32_t vlen) {
  uint32_t klen = strlen(key);
  size_t body_len = 8 + klen + (vlen == TOMBSTONE ? 0 : vlen);
  size_t rec_len = 4 + body_len;
  uint8_t *rec = malloc(rec_len);

  uint8_t *b = rec + 4;
  memcpy(b + 0, &klen, 4);
  memcpy(b + 4, &vlen, 4);
  memcpy(b + 8, key, klen);
  if (vlen != TOMBSTONE) memcpy(b + 8 + klen, val, vlen);

  uint32_t crc = crc32(0, b, body_len);
  memcpy(rec, &crc, 4);

  bool tear = io_point();
  if (!write_all(fd, rec, rec_len, tear)) { free(rec); return false; }
  free(rec);
  return true;
}

// The durability boundary. Until this returns, every record written since the
// last one is in the page cache and not on the platter.
//
// There is no such thing as half an fsync, so a torn request here degrades to
// a plain crash. Without that, WALKV_TORN silently skips every fsync boundary
// and the run completes uncrashed -- which it did, for a while.
static bool wal_sync(int fd) {
  if (io_point()) _exit(99);
  if (!bug_is("no-fsync") && fsync(fd) < 0) return false;
  return true;
}

// "durable J" to stdout, with write(2) rather than printf. The process is
// about to be killed at an arbitrary point by the crash harness, and an
// acknowledgement sitting in a stdio buffer that _exit discards is one nobody
// can hold us to.
static bool ack_durable(long j) {
  char buf[64];
  int m = snprintf(buf, sizeof(buf), "durable %ld\n", j);
  return write(1, buf, (size_t)m) == m;
}

// One record, written and made durable: the original per-record contract.
static bool wal_append(DB *db, const char *key, const uint8_t *val, uint32_t vlen) {
  return wal_write(db->fd, key, val, vlen) && wal_sync(db->fd);
}

// ---------------------------------------------------------------- recovery

// A complete, valid record for a four byte key with an empty value, written at
// the current offset with raw write(2) so that it adds no io_point() and
// cannot change the size of the scenario matrix. Only the planted defects
// below use it.
static void bug_record(int fd, const char *key) {
  uint8_t rec[16];
  uint32_t klen = 4, vlen = 0;
  memcpy(rec + 4, &klen, 4);
  memcpy(rec + 8, &vlen, 4);
  memcpy(rec + 12, key, 4);
  uint32_t crc = crc32(0, rec + 4, 12);
  memcpy(rec, &crc, 4);
  if (write(fd, rec, sizeof rec) != (ssize_t)sizeof rec) perror("bug_record");
}

// Replays the log into the index, stopping at the first short or corrupt
// record. Returns the number of records applied.
static char *tmp_path(const char *path) {
  size_t n = strlen(path) + sizeof ".compact";
  char *t = malloc(n);
  snprintf(t, n, "%s.compact", path);
  return t;
}

static long recover(DB *db) {
  // A leftover DB.compact is garbage by definition: rename(2) is compaction's
  // commit point, so anything still sitting under the temp name is a
  // compaction that did not commit, and the log it was built from is still
  // whole. Dropping it is the first of recovery's two mutating syscalls --
  // which is what makes recovery multi-step, and therefore what makes the
  // idempotence pass in t/crash.sh say something it did not say before.
  char *tmp = tmp_path(db->path);
  if (access(tmp, F_OK) == 0) {
    // The boundary is taken whichever branch runs, so the planted defects
    // below do not change the size of the scenario matrix. A defect that
    // shrinks the matrix is caught by the pin rather than by the oracle, and
    // then it is the pin that gets the credit.
    if (io_point()) _exit(99);
    if (bug_is("compact-prefer-tmp")) {
      // bug: treat the uncommitted temp as authoritative. Correct exactly
      // when the crash happened to land after the last record was written,
      // and a total loss of everything not yet copied otherwise.
      close(db->fd);
      if (rename(tmp, db->path) < 0) { free(tmp); return -1; }
      db->fd = open(db->path, O_RDWR);
      if (db->fd < 0) { free(tmp); return -1; }
    } else if (!bug_is("compact-keep-tmp")) {
      if (unlink(tmp) < 0) { free(tmp); return -1; }
    }
    // bug compact-keep-tmp: leak it. The log is right, so the model oracle
    // sees nothing; only the filesystem check does.
  }
  free(tmp);

  if (lseek(db->fd, 0, SEEK_SET) < 0) return -1;

  long applied = 0;
  uint8_t hdr[12];
  // Offset of the start of the record we are about to read. If that record
  // turns out to be short or corrupt, this is where the log really ends.
  off_t good = 0;

  for (;;) {
    good = lseek(db->fd, 0, SEEK_CUR);
    ssize_t n = read(db->fd, hdr, 12);
    if (n == 0) break;                      // clean end of log
    if (n < 12 && !bug_is("accept-short")) break;   // torn header
    if (n < 12) memset(hdr + n, 0, 12 - (size_t)n);  // bug: pad and carry on

    uint32_t crc, klen, vlen;
    memcpy(&crc,  hdr + 0, 4);
    memcpy(&klen, hdr + 4, 4);
    memcpy(&vlen, hdr + 8, 4);

    // Sanity-check lengths before trusting them enough to allocate.
    if (klen == 0 || klen > MAX_KEY) break;
    if (vlen != TOMBSTONE && vlen > MAX_VAL) break;

    uint32_t payload = (vlen == TOMBSTONE) ? 0 : vlen;
    size_t body_len = 8 + klen + payload;
    uint8_t *body = malloc(body_len);
    memcpy(body, hdr + 4, 8);

    ssize_t got = read(db->fd, body + 8, klen + payload);
    if (got < 0 || (size_t)got < klen + payload) { free(body); break; }  // torn body

    if (!bug_is("no-crc") && crc32(0, body, body_len) != crc) {
      free(body); break;                                                 // corrupt
    }

    // Exactly klen + 1 bytes, not a MAX_KEY-sized buffer with slack at the
    // end. A buffer larger than its data turns the sanitizer off: a read one
    // past the key lands inside a live 1025-byte allocation and ASan says
    // nothing. This is the shape that was found seven times across the
    // sibling repos, so it is sized to the data here too.
    char *key = malloc((size_t)klen + 1);
    memcpy(key, body + 8, klen);
    key[klen] = 0;

#ifdef WALKV_PROBE_OVERREAD
    // Compiled only by `make overread`. A deliberate read one byte past the
    // key, whose point is not the read but whether the SANITIZER SEES IT.
    // With a MAX_KEY-sized buffer here instead of malloc(klen + 1) this
    // identical read lands inside a live 1025-byte object: measured, the run
    // prints "3 keys" and neither ASan nor UBSan says a word. So the trimming
    // above is checked rather than trusted, and reintroducing a buffer larger
    // than its data turns the suite red instead of quietly turning the
    // sanitizer off over the whole recovery parser.
    { volatile char probe = key[klen + 1]; (void)probe; }
#endif
    if (vlen == TOMBSTONE) index_del(db, key);
    else                   index_put(db, key, body + 8 + klen, vlen);

    free(key);
    free(body);
    applied++;
  }

  // Drop whatever followed the last good record, so the next append starts from
  // a clean boundary instead of after garbage.
  if (bug_is("truncate-cursor")) good = lseek(db->fd, 0, SEEK_CUR);

  // bug repair-tail: mend the bad tail into a well formed record before
  // deciding to drop it. The mend is durable, the decision is not, so a crash
  // in the window between them leaves a fabricated record that the next
  // recovery reads as real data. Recovering once and recovering through a
  // crash then land in different places.
  if (bug_is("repair-tail")) {
    if (lseek(db->fd, good, SEEK_SET) < 0) return -1;
    bug_record(db->fd, "fix!");
  }

  // Recovery's own I/O boundary. The truncate is the only thing recovery makes
  // durable, so it is the only point at which a crash during recovery can
  // leave the log half dealt with. A torn truncate is not a thing, so the hook
  // degrades to a plain crash here, as it does at an fsync.
  if (io_point()) _exit(99);
  if (ftruncate(db->fd, good) < 0) return -1;
  if (lseek(db->fd, good, SEEK_SET) < 0) return -1;

  // bug recover-marker: write an audit record saying recovery ran. Plausible,
  // and not a fixpoint: every re-run of recovery adds another one, so
  // recovering twice differs from recovering once.
  if (bug_is("recover-marker")) bug_record(db->fd, "mark");
  return applied;
}

static DB *db_open(const char *path) {
  DB *db = calloc(1, sizeof(DB));
  db->path = path;
  db->fd = open(path, O_RDWR | O_CREAT, 0644);
  if (db->fd < 0) { perror("open"); exit(1); }
  if (recover(db) < 0) { perror("recover"); exit(1); }
  return db;
}

// -------------------------------------------------------------- compaction
//
// The log grows forever otherwise: twenty overwrites of one key are twenty
// records, and a delete adds a record rather than removing one. Compaction
// rewrites the log as one record per live key -- which is the single most
// dangerous operation a log store performs, because for the length of it the
// old log and the new one both exist and exactly one of them is the truth.
//
// The sequence, and the reason for its order:
//
//   1. write every live record into DB.compact      (one boundary each)
//   2. fsync it                                     (one boundary)
//   3. rename(DB.compact, DB)                       (one boundary) <- commit
//   4. fsync the directory                          (one boundary)
//
// rename(2) is the commit point and it is atomic, so there is no instant at
// which DB is a partially written log. Every crash before step 3 leaves the
// old log untouched and a temp file to be swept up; every crash after it
// leaves the new log. There is no third outcome, and that is the whole claim
// that t/crash.sh checks against the model oracle at each of these boundaries.
//
// Step 4 is the one a process-kill harness cannot test, for the same reason
// no-fsync is invisible: the rename is in the page cache and the kernel
// outlives the process. It is here because it is correct, not because
// anything here can prove it is needed. See the ceiling note in README.
static bool fsync_dir(const char *path) {
  char *d = strdup(path);
  char *slash = strrchr(d, '/');
  if (slash == d) d[1] = 0;            // "/db" -> "/"
  else if (slash)  *slash = 0;
  else             strcpy(d, ".");
  int fd = open(d, O_RDONLY);
  free(d);
  if (fd < 0) return false;
  int rc = fsync(fd);
  close(fd);
  return rc == 0;
}

// Returns the number of records written, or -1.
static long compact(DB *db) {
  char *tmp = tmp_path(db->path);
  int tfd;

  if (bug_is("compact-inplace")) {
    // bug: skip the temp file and rewrite the log where it lies. The classic
    // way to get this wrong, and it loses everything not yet rewritten at
    // every single boundary, because for the duration of the rewrite the one
    // copy of the data is half a copy.
    if (ftruncate(db->fd, 0) < 0 || lseek(db->fd, 0, SEEK_SET) < 0) goto bad;
    tfd = db->fd;
  } else {
    tfd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (tfd < 0) goto bad;
  }

  long n = 0;
  for (int i = 0; i < NBUCKETS; i++) {
    for (Entry *e = db->buckets[i]; e; e = e->next) {
      if (!wal_write(tfd, e->key, e->val, e->vlen)) goto bad;
      n++;
    }
  }
  // The new log is made durable BEFORE the rename that commits it, which is
  // the whole reason the order above is written down. bug compact-sync-late
  // does it the other way round: identical boundaries, identical count, and
  // the commit of a log whose bytes are not yet on the platter. Asserted
  // MISSED in t/mutants.sh, because a process-kill harness cannot tell -- the
  // boundary count is kept identical on purpose, so the matrix-size pin
  // cannot be mistaken for a durability check that noticed.
  bool late = bug_is("compact-sync-late");
  if (io_point()) _exit(99);                      // the fsync boundary
  if (!late && fsync(tfd) < 0) goto bad;

  if (io_point()) _exit(99);                      // the commit boundary
  if (!bug_is("compact-inplace")) {
    if (rename(tmp, db->path) < 0) goto bad;
    close(db->fd);
    db->fd = tfd;                                 // tfd is now DB
  }
  if (late && fsync(db->fd) < 0) goto bad;

  if (io_point()) _exit(99);                      // the directory boundary
  if (!fsync_dir(db->path)) goto bad;

  free(tmp);
  return n;
bad:
  free(tmp);
  return -1;
}

// ---------------------------------------------------------------------- CLI

static int usage(void) {
  fprintf(stderr,
    "usage: walkv DB put KEY VAL\n"
    "       walkv DB get KEY\n"
    "       walkv DB del KEY\n"
    "       walkv DB bulk N          put k0..k(N-1), fsync each\n"
    "       walkv DB batch N B       put k0..k(N-1), fsync every B of them,\n"
    "                                printing 'durable J' after each fsync\n"
    "       walkv DB verify-prefix N check the prefix invariant\n"
    "       walkv DB recover         replay only, report record count\n"
    "       walkv DB compact         rewrite the log as one record per live key\n"
    "\n"
    "test hooks: WALKV_CRASH_AT=n WALKV_TORN=1 WALKV_COUNT_IO=1\n");
  return 2;
}

int main(int argc, char **argv) {
  io_hook_init();
  if (argc < 3) return usage();
  const char *path = argv[1];
  const char *cmd = argv[2];

  DB *db = db_open(path);

  if (!strcmp(cmd, "put") && argc == 5) {
    if (!wal_append(db, argv[3], (uint8_t *)argv[4], strlen(argv[4]))) {
      perror("put"); return 1;
    }
    index_put(db, argv[3], (uint8_t *)argv[4], strlen(argv[4]));

  } else if (!strcmp(cmd, "get") && argc == 4) {
    Entry *e = *find_slot(db, argv[3]);
    if (!e) { fprintf(stderr, "not found\n"); return 1; }
    fwrite(e->val, 1, e->vlen, stdout);
    putchar('\n');

  } else if (!strcmp(cmd, "del") && argc == 4) {
    if (!wal_append(db, argv[3], NULL, TOMBSTONE)) { perror("del"); return 1; }
    index_del(db, argv[3]);

  } else if (!strcmp(cmd, "bulk") && argc == 4) {
    long n = strtol(argv[3], NULL, 10);
    for (long i = 0; i < n; i++) {
      char k[32], v[32];
      snprintf(k, sizeof(k), "k%ld", i);
      snprintf(v, sizeof(v), "v%ld", i);
      if (!wal_append(db, k, (uint8_t *)v, strlen(v))) { perror("bulk"); return 1; }
      index_put(db, k, (uint8_t *)v, strlen(v));
    }

  } else if (!strcmp(cmd, "batch") && argc == 5) {
    // Group B puts into one fsync. This is where real stores go wrong: the
    // per-record contract says "once put returns, it survives", and batching
    // deliberately weakens that to "once a batch is acknowledged, every record
    // in it survives". The weaker claim is still a claim, and the harness has
    // to be able to check it.
    //
    // So the acknowledgement is made visible. After every successful fsync,
    // "durable J" goes to stdout with write(2) rather than printf: the process
    // is about to be killed at an arbitrary point by the crash harness, and a
    // stdio buffer discarded by _exit is an acknowledgement nobody can hold us
    // to. The harness reads the last such line and requires the recovered
    // prefix to cover it.
    long n = strtol(argv[3], NULL, 10);
    long bsz = strtol(argv[4], NULL, 10);
    if (bsz < 1) { fprintf(stderr, "batch: B must be at least 1\n"); return 2; }

    for (long i = 0; i < n; i++) {
      char k[32], v[32];
      snprintf(k, sizeof(k), "k%ld", i);
      snprintf(v, sizeof(v), "v%ld", i);
      if (!wal_write(db->fd, k, (uint8_t *)v, strlen(v))) { perror("batch"); return 1; }
      index_put(db, k, (uint8_t *)v, strlen(v));

      // Sync at the end of each batch, and at the end of the run so a final
      // short batch is acknowledged too rather than silently left in the cache.
      if ((i + 1) % bsz == 0 || i + 1 == n) {
        // Claiming durability before the fsync returns is the classic version
        // of this bug, and a process-kill harness cannot see it: see
        // t/mutants.sh, where it is asserted to be MISSED for the same reason
        // no-fsync is.
        bool early = bug_is("ack-before-sync");
        if (early && !ack_durable(i + 1)) { perror("batch: ack"); return 1; }
        if (!wal_sync(db->fd)) { perror("batch"); return 1; }
        if (!early && !ack_durable(i + 1)) { perror("batch: ack"); return 1; }
      }
    }

  } else if (!strcmp(cmd, "verify-prefix") && argc == 4) {
    // The invariant: after any crash, the surviving keys must be k0..k(j-1) for
    // some j, with correct values, and nothing at or past j. A gap means we lost
    // a record that an earlier fsync already acknowledged.
    long n = strtol(argv[3], NULL, 10);
    long j = 0;
    while (j < n) {
      char k[32], want[32];
      snprintf(k, sizeof(k), "k%ld", j);
      snprintf(want, sizeof(want), "v%ld", j);
      Entry *e = *find_slot(db, k);
      if (!e) break;
      if (e->vlen != strlen(want) || memcmp(e->val, want, e->vlen)) {
        printf("CORRUPT at k%ld\n", j);
        return 1;
      }
      j++;
    }
    for (long i = j; i < n; i++) {
      char k[32];
      snprintf(k, sizeof(k), "k%ld", i);
      if (*find_slot(db, k)) { printf("GAP: k%ld missing but k%ld present\n", j, i); return 1; }
    }
    printf("prefix %ld\n", j);

  } else if (!strcmp(cmd, "compact")) {
    long n = compact(db);
    if (n < 0) { perror("compact"); return 1; }
    printf("%ld records\n", n);

  } else if (!strcmp(cmd, "recover")) {
    // db_open already replayed; just report what the index holds.
    long count = 0;
    for (int i = 0; i < NBUCKETS; i++)
      for (Entry *e = db->buckets[i]; e; e = e->next) count++;
    printf("%ld keys\n", count);

  } else {
    return usage();
  }

  if (counting) fprintf(stderr, "io_points %ld\n", io_points);
  return 0;
}
