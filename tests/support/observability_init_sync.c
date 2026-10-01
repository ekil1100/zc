/* Test-only, process-scoped cold log lock sync injection. */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <dlfcn.h>
#endif

static int file_seen, directory_seen;

static int inject(int fd) {
    const char *root = getenv("ZC_LOG_INIT_ROOT");
    const char *mode = getenv("ZC_LOG_INIT_CASE");
    if (!root || !mode) return 0;
    char path[PATH_MAX], target[PATH_MAX];
#ifdef __APPLE__
    if (fcntl(fd, F_GETPATH, path)) return 0;
#else
    char link[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, path, sizeof(path) - 1);
    if (n < 0) return 0;
    path[n] = '\0';
#endif
    snprintf(target, sizeof(target), "%s/zc.log.lock", root);
    struct stat st;
    if (fstat(fd, &st)) return 0;
    char marker;
    if (!file_seen && S_ISREG(st.st_mode) && !strcmp(path, target)) {
        file_seen = 1;
        marker = 'F';
    } else if (file_seen && !directory_seen && S_ISDIR(st.st_mode) && !strcmp(path, root)) {
        directory_seen = 1;
        marker = 'D';
    } else return 0;
    snprintf(target, sizeof(target), "%s/sync-markers", root);
    int out = open(target, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (out < 0 || write(out, &marker, 1) != 1 || close(out)) _exit(90);
    if ((marker == 'F' && !strcmp(mode, "file-eio")) ||
        (marker == 'D' && !strcmp(mode, "directory-eio"))) {
        errno = EIO;
        return 1;
    }
    if (marker == 'F') {
        long ms = !strcmp(mode, "expired") ? 1100 : 75;
        struct timespec delay = { ms / 1000, (ms % 1000) * 1000000 };
        while (nanosleep(&delay, &delay) && errno == EINTR) {}
    }
    return 0;
}

#ifdef __APPLE__
static int traced_fsync(int fd) {
    if (inject(fd)) return -1;
    return fsync(fd);
}
static int traced_fcntl(int fd, int cmd, ...) {
    if (cmd == F_FULLFSYNC) {
        if (inject(fd)) return -1;
        return fcntl(fd, cmd);
    }
    if (cmd == F_GETFD || cmd == F_GETFL || cmd == F_GETOWN) return fcntl(fd, cmd);
    va_list ap;
    va_start(ap, cmd);
    uintptr_t arg = va_arg(ap, uintptr_t);
    va_end(ap);
    return fcntl(fd, cmd, arg);
}
#define INTERPOSE(replacement, original) \
 __attribute__((used)) static struct { const void *replacement; const void *original; } pair_##original \
 __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original };
INTERPOSE(traced_fsync, fsync)
INTERPOSE(traced_fcntl, fcntl)
#else
int fsync(int fd) {
    static int (*real_fsync)(int);
    if (!real_fsync) real_fsync = dlsym(RTLD_NEXT, "fsync");
    if (!real_fsync) _exit(90);
    if (inject(fd)) return -1;
    return real_fsync(fd);
}
#endif
