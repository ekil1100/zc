/* Test-only scheduling of a real restart reader against daemon exit cleanup.
 * Syscall results and stat snapshots are never fabricated or modified. */
#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE
#include <sys/file.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <dlfcn.h>
#include <sys/sysmacros.h>
#endif

static atomic_uint snapshots;
static atomic_int fired;

static void fail(const char *operation) {
    perror(operation);
    _exit(90);
}

static void path_for(char *path, size_t size, const char *name) {
    const char *root = getenv("ZC_RESTART_CAPTURE_ROOT");
    int n = root ? snprintf(path, size, "%s/%s", root, name) : -1;
    if (n < 0 || (size_t)n >= size) fail("invalid restart capture scope");
}

static int present(const char *name) {
    char path[4096];
    path_for(path, sizeof(path), name);
    if (!access(path, F_OK)) return 1;
    if (errno != ENOENT) fail("check restart capture gate");
    return 0;
}

static void record(const char *name, const char *text) {
    char path[4096];
    path_for(path, sizeof(path), name);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0 && errno == EEXIST) return;
    if (fd < 0 || write(fd, text, strlen(text)) != (ssize_t)strlen(text) || close(fd))
        fail("write restart capture evidence");
}

static int scope(const char *role, uint64_t *dev, uint64_t *ino) {
    const char *actual = getenv("ZC_RESTART_CAPTURE_ROLE");
    if (!actual || strcmp(actual, role)) return 0;
    char path[4096], text[256];
    path_for(path, sizeof(path), "armed");
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 && errno == ENOENT) return 0;
    if (fd < 0) fail("open restart capture scope");
    ssize_t n = read(fd, text, sizeof(text) - 1);
    if (n <= 0 || (size_t)n >= sizeof(text) - 1 || close(fd))
        fail("read restart capture scope");
    text[n] = '\0';
    unsigned long long dd, di, ld, li;
    char extra;
    if (sscanf(text, "%llu %llu %llu %llu %c", &dd, &di, &ld, &li, &extra) != 4)
        fail("malformed restart capture scope");
    *dev = !strcmp(role, "reader") ? dd : ld;
    *ino = !strcmp(role, "reader") ? di : li;
    return 1;
}

static void capture(int fd, uint64_t dev, uint64_t ino, mode_t mode,
                    uid_t uid, uint64_t nlink) {
    uint64_t target_dev, target_ino;
    if (atomic_load(&fired) || !scope("reader", &target_dev, &target_ino) ||
        dev != target_dev || ino != target_ino) return;
    const char *request = getenv("ZC_RESTART_CAPTURE_REQUEST");
    if (!request) fail("missing stop request scope");
    if (access(request, F_OK)) {
        if (errno != ENOENT) fail("check stop request");
        return;
    }
    /* The daemon is suspended until capture-before: checked-open is snapshot 1. */
    if (atomic_fetch_add(&snapshots, 1) + 1 != 2) return;
    if (atomic_exchange(&fired, 1)) fail("duplicate restart reader");
    if (!S_ISREG(mode) || uid != geteuid() || nlink != 1 || (mode & 077) ||
        (fcntl(fd, F_GETFL) & O_ACCMODE) != O_RDONLY)
        fail("invalid restart capture-before");
    char evidence[256];
    snprintf(evidence, sizeof(evidence), "dev=%llu ino=%llu nlink=1\n",
             (unsigned long long)dev, (unsigned long long)ino);
    record("reader-ready", evidence);
    struct timespec start, now;
    if (clock_gettime(CLOCK_MONOTONIC, &start)) fail("capture clock");
    while (!present("reader-release")) {
        if (clock_gettime(CLOCK_MONOTONIC, &now) || now.tv_sec - start.tv_sec >= 10)
            fail("restart reader watchdog");
        usleep(1000);
    }
    struct stat after;
    if (fstat(fd, &after) || (uint64_t)after.st_dev != dev || (uint64_t)after.st_ino != ino)
        fail("verify captured descriptor");
    snprintf(evidence, sizeof(evidence), "dev=%llu ino=%llu nlink=%llu\n",
             (unsigned long long)dev, (unsigned long long)ino,
             (unsigned long long)after.st_nlink);
    record("reader-after", evidence);
}

static void writer_lock(int fd, int operation, int result, int error) {
    uint64_t dev, ino;
    if (!(operation & LOCK_EX) || !scope("writer", &dev, &ino)) return;
    struct stat st;
    if (fstat(fd, &st)) fail("stat cleanup lock");
    if ((uint64_t)st.st_dev != dev || (uint64_t)st.st_ino != ino) return;
    if (!result) record("writer-lock", "acquired\n");
    else if (error == EWOULDBLOCK || error == EAGAIN) record("writer-lock", "blocked\n");
    else fail("unexpected cleanup lock result");
}

#ifdef __APPLE__
static int capture_fstat(int fd, struct stat *st) {
    int result = fstat(fd, st), error = errno;
    if (!result) capture(fd, st->st_dev, st->st_ino, st->st_mode, st->st_uid, st->st_nlink);
    errno = error;
    return result;
}
static int capture_flock(int fd, int operation) {
    int result = flock(fd, operation), error = errno;
    writer_lock(fd, operation, result, error);
    errno = error;
    return result;
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } pair_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original }
INTERPOSE(capture_fstat, fstat);
INTERPOSE(capture_flock, flock);
#else
int fstat(int fd, struct stat *st) {
    int (*real)(int, struct stat *) = dlsym(RTLD_NEXT, "fstat");
    if (!real) fail("resolve fstat");
    int result = real(fd, st), error = errno;
    if (!result) capture(fd, st->st_dev, st->st_ino, st->st_mode, st->st_uid, st->st_nlink);
    errno = error;
    return result;
}
#ifdef __GLIBC__
int fstat64(int fd, struct stat64 *st) {
    int (*real)(int, struct stat64 *) = dlsym(RTLD_NEXT, "fstat64");
    if (!real) fail("resolve fstat64");
    int result = real(fd, st), error = errno;
    if (!result) capture(fd, st->st_dev, st->st_ino, st->st_mode, st->st_uid, st->st_nlink);
    errno = error;
    return result;
}
#endif
int statx(int fd, const char *path, int flags, unsigned mask, struct statx *st) {
    int (*real)(int, const char *, int, unsigned, struct statx *) = dlsym(RTLD_NEXT, "statx");
    if (!real) fail("resolve statx");
    int result = real(fd, path, flags, mask, st), error = errno;
    if (!result && (flags & AT_EMPTY_PATH) && !*path)
        capture(fd, makedev(st->stx_dev_major, st->stx_dev_minor), st->stx_ino,
                st->stx_mode, st->stx_uid, st->stx_nlink);
    errno = error;
    return result;
}
int flock(int fd, int operation) {
    int (*real)(int, int) = dlsym(RTLD_NEXT, "flock");
    if (!real) fail("resolve flock");
    int result = real(fd, operation), error = errno;
    writer_lock(fd, operation, result, error);
    errno = error;
    return result;
}
#endif
