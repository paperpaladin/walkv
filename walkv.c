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

// Appends one record and makes it durable. Returns false on I/O error.
static bool wal_append(DB *db, const char *key, const uint8_t *val, uint32_t vlen) {
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
  if (!write_all(db->fd, rec, rec_len, tear)) { free(rec); return false; }
  free(rec);

  // The record is in the page cache but not on the platter until this returns.
  // A crash between the write and the fsync must still leave a valid prefix,
  // which is exactly what the harness checks.
  // There is no such thing as half an fsync, so a torn request at this boundary
  // degrades to a plain crash. Without this, WALKV_TORN silently skips every
  // fsync boundary and the run completes uncrashed.
  if (io_point()) _exit(99);
  if (!bug_is("no-fsync") && fsync(db->fd) < 0) return false;
  return true;
}

// ---------------------------------------------------------------- recovery

// Replays the log into the index, stopping at the first short or corrupt
// record. Returns the number of records applied.
static long recover(DB *db) {
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

    char key[MAX_KEY + 1];
    memcpy(key, body + 8, klen);
    key[klen] = 0;

    if (vlen == TOMBSTONE) index_del(db, key);
    else                   index_put(db, key, body + 8 + klen, vlen);

    free(body);
    applied++;
  }

  // Drop whatever followed the last good record, so the next append starts from
  // a clean boundary instead of after garbage.
  if (bug_is("truncate-cursor")) good = lseek(db->fd, 0, SEEK_CUR);
  if (ftruncate(db->fd, good) < 0) return -1;
  if (lseek(db->fd, good, SEEK_SET) < 0) return -1;
  return applied;
}

static DB *db_open(const char *path) {
  DB *db = calloc(1, sizeof(DB));
  db->fd = open(path, O_RDWR | O_CREAT, 0644);
  if (db->fd < 0) { perror("open"); exit(1); }
  if (recover(db) < 0) { perror("recover"); exit(1); }
  return db;
}

// ---------------------------------------------------------------------- CLI

static int usage(void) {
  fprintf(stderr,
    "usage: walkv DB put KEY VAL\n"
    "       walkv DB get KEY\n"
    "       walkv DB del KEY\n"
    "       walkv DB bulk N          put k0..k(N-1), fsync each\n"
    "       walkv DB verify-prefix N check the prefix invariant\n"
    "       walkv DB recover         replay only, report record count\n"
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
