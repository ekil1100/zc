/* Test-only syscall-boundary injection. Never alter the returned stat snapshot. */
#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
#include <dlfcn.h>
#include <sys/sysmacros.h>
#endif

/* Avoid TLS initialization inside loader-time metadata calls. */
static atomic_uint seen;
static atomic_int fired;

static void fail(const char *operation) {
    perror(operation);
    _exit(90);
}

/* Separate scope: schedule real descriptor publication, never mutate a stat. */
static atomic_uint_fast64_t descriptor_disarmed;
static _Thread_local uint64_t descriptor_epoch;
static _Thread_local unsigned descriptor_snapshots;
static _Thread_local int descriptor_fd;

static void exchange_epoch(int socket_fd, uint64_t epoch) {
    const unsigned char *out = (const unsigned char *)&epoch;
    size_t sent = 0;
    while (sent < sizeof(epoch)) {
        ssize_t n = write(socket_fd, out + sent, sizeof(epoch) - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("notify descriptor writer");
        sent += (size_t)n;
    }
    uint64_t ack = 0;
    unsigned char *in = (unsigned char *)&ack;
    size_t received = 0;
    while (received < sizeof(ack)) {
        ssize_t n = read(socket_fd, in + received, sizeof(ack) - received);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("await descriptor writer ACK");
        received += (size_t)n;
    }
    if (ack != epoch) fail("wrong descriptor writer epoch");
}

static void descriptor_overlap(int fd, uint64_t dev, uint64_t ino, mode_t mode,
                               uid_t uid, uint64_t nlink) {
    const char *control = getenv("ZC_DESCRIPTOR_RACE_CONTROL");
    if (!control) return;
    int arm = open(control, O_RDONLY | O_NOFOLLOW);
    if (arm < 0) {
        if (errno == ENOENT) return; /* Child setup has not armed a round yet. */
        fail("open descriptor control");
    }
    char record[128];
    ssize_t length = read(arm, record, sizeof(record) - 1);
    if (close(arm)) fail("close descriptor control");
    if (length <= 0 || (size_t)length >= sizeof(record) - 1)
        fail("malformed descriptor control");
    record[length] = '\0';
    unsigned long long device, inode, epoch;
    char extra;
    if (sscanf(record, "%llu %llu %llu %c", &device, &inode, &epoch, &extra) != 3 ||
        !epoch || epoch > 500) fail("malformed descriptor control");
    uint_fast64_t previous = atomic_load(&descriptor_disarmed);
    if (epoch == previous) return;
    if (epoch != previous + 1) fail("out-of-order descriptor control");
    if (dev != device || ino != inode) return;
    /* Only this reader's second fd snapshot: checked-open, then capture-before.
       TLS is accessed only inside the explicit, armed runtime scope. */
    if (descriptor_epoch != epoch) {
        descriptor_epoch = epoch;
        descriptor_snapshots = 0;
        descriptor_fd = fd;
    }
    if (fd != descriptor_fd) fail("descriptor reader changed fd");
    if (++descriptor_snapshots != 2) return;
    if (!S_ISREG(mode) || uid != geteuid() || nlink != 1 || (mode & 077) ||
        (fcntl(fd, F_GETFL) & O_ACCMODE) != O_RDONLY)
        fail("invalid descriptor capture-before");
    /* Disarm BEFORE notifying the writer: its checked-open and the verification
       below must remain real and must never recursively enter the handshake. */
    if (!atomic_compare_exchange_strong(&descriptor_disarmed, &previous, epoch))
        fail("duplicate descriptor reader");
    const char *path = getenv("ZC_DESCRIPTOR_RACE_SOCKET");
    const char *marker = getenv("ZC_DESCRIPTOR_RACE_MARKER");
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (!path || !marker || strlen(path) >= sizeof(address.sun_path))
        fail("invalid descriptor socket scope");
    strcpy(address.sun_path, path);
    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct timeval timeout = { .tv_sec = 10, .tv_usec = 0 };
    if (socket_fd < 0 ||
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) ||
        connect(socket_fd, (struct sockaddr *)&address, sizeof(address)))
        fail("connect descriptor writer");
    exchange_epoch(socket_fd, epoch);
    if (close(socket_fd)) fail("close descriptor writer socket");
    struct stat after;
    if (fstat(fd, &after) || (uint64_t)after.st_dev != dev ||
        (uint64_t)after.st_ino != ino || after.st_nlink != 0)
        fail("descriptor old fd was not unlinked");
    int size = snprintf(record, sizeof(record),
                        "DESCRIPTOR_CAPTURE %llu %llu %llu nlink=0\n", epoch, device, inode);
    int mark = open(marker, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (size <= 0 || (size_t)size >= sizeof(record) || mark < 0 ||
        write(mark, record, (size_t)size) != size || close(mark))
        fail("write descriptor overlap marker");
    /* The caller returns its ORIGINAL successful snapshot, completely intact. */
}

static void inject(int fd, uint64_t dev, uint64_t ino, mode_t mode,
                   uid_t uid, uint64_t nlink) {
    descriptor_overlap(fd, dev, ino, mode, uid, nlink);
    const char *target = getenv("ZC_READ_RACE_TARGET");
    const char *device = getenv("ZC_READ_RACE_DEV");
    const char *inode = getenv("ZC_READ_RACE_INO");
    if (fired || !target || !device || !inode ||
        dev != strtoull(device, NULL, 10) || ino != strtoull(inode, NULL, 10)) return;
    const char *action = getenv("ZC_READ_RACE_ACTION");
    const char *snapshot = getenv("ZC_READ_RACE_SNAPSHOT");
    const char *marker = getenv("ZC_READ_RACE_MARKER");
    const char *alias = getenv("ZC_READ_RACE_ALIAS");
    if (!action || !snapshot || !marker || !alias) fail("missing injection scope");
    if (++seen != strtoul(snapshot, NULL, 10)) return;
    fired = 1; /* Verification and every subsequent metadata call remain real. */
    struct stat named;
    if (!S_ISREG(mode) || uid != geteuid() || nlink != 1 ||
        lstat(target, &named) || (uint64_t)named.st_dev != dev ||
        (uint64_t)named.st_ino != ino) fail("invalid initial inode");
    int result;
    if (!strcmp(action, "unlink")) {
        result = unlink(target);
    } else if (!strcmp(action, "hardlink")) {
        result = link(target, alias);
    } else if (!strcmp(action, "private-chmod")) {
        if (mode & 077) fail("initial file is not private");
        result = fchmod(fd, 0644);
    } else if (!strcmp(action, "cache-chmod")) {
        if (mode & 022) fail("initial cache is writable by others");
        result = fchmod(fd, 0664);
    } else {
        fail("unknown injection action");
        return;
    }
    if (result) fail("inode mutation");
    struct stat after;
    if (fstat(fd, &after) || (uint64_t)after.st_dev != dev ||
        (uint64_t)after.st_ino != ino) fail("verify mutated inode");
    if ((!strcmp(action, "unlink") && after.st_nlink != 0) ||
        (!strcmp(action, "hardlink") && after.st_nlink != 2) ||
        (!strcmp(action, "private-chmod") && (after.st_mode & 0777) != 0644) ||
        (!strcmp(action, "cache-chmod") && (after.st_mode & 0777) != 0664))
        fail("mutation not visible");
    char record[128];
    int length = snprintf(record, sizeof(record), "INJECT_READ_CAPTURE %s snapshot=%u\n", action, seen);
    int mark = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (mark < 0 || write(mark, record, (size_t)length) != length || close(mark))
        fail("write injection marker");
}

#ifdef __APPLE__
static int captured_fstat(int fd, struct stat *st) {
    int result = fstat(fd, st);
    int saved_errno = errno;
    if (!result) inject(fd, st->st_dev, st->st_ino, st->st_mode, st->st_uid, st->st_nlink);
    errno = saved_errno;
    return result;
}
/* The SDK selects fstat$INODE64 on macOS x64 and fstat on arm64. */
__attribute__((used)) static struct { const void *replacement; const void *original; } pair_fstat
__attribute__((section("__DATA,__interpose"))) = { (const void *)&captured_fstat, (const void *)&fstat };
#else
/* Rust std uses libc metadata wrappers, even when rustix opens via raw syscalls. */
int fstat(int fd, struct stat *st) {
    int (*real)(int, struct stat *) = dlsym(RTLD_NEXT, "fstat");
    if (!real) fail("resolve fstat");
    int result = real(fd, st);
    int saved_errno = errno;
    if (!result) inject(fd, st->st_dev, st->st_ino, st->st_mode, st->st_uid, st->st_nlink);
    errno = saved_errno;
    return result;
}
#ifdef __GLIBC__
int fstat64(int fd, struct stat64 *st) {
    int (*real)(int, struct stat64 *) = dlsym(RTLD_NEXT, "fstat64");
    if (!real) fail("resolve fstat64");
    int result = real(fd, st);
    int saved_errno = errno;
    if (!result) inject(fd, st->st_dev, st->st_ino, st->st_mode, st->st_uid, st->st_nlink);
    errno = saved_errno;
    return result;
}
#endif
int statx(int fd, const char *path, int flags, unsigned mask, struct statx *st) {
    int (*real)(int, const char *, int, unsigned, struct statx *) = dlsym(RTLD_NEXT, "statx");
    if (!real) fail("resolve statx");
    int result = real(fd, path, flags, mask, st);
    int saved_errno = errno;
    /* Only descriptor metadata: path walks and unrelated inodes are untouched. */
    if (!result && (flags & AT_EMPTY_PATH) && !*path)
        inject(fd, makedev(st->stx_dev_major, st->stx_dev_minor), st->stx_ino,
               st->stx_mode, st->stx_uid, st->stx_nlink);
    errno = saved_errno;
    return result;
}
#endif
