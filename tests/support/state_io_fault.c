#include <sys/stat.h>
#include <sys/param.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fail_sync(int fd) {
    char path[MAXPATHLEN];
    struct stat st;
    if (fcntl(fd, F_GETPATH, path) || fstat(fd, &st) || !S_ISDIR(st.st_mode)) return 0;
    char record[2 * MAXPATHLEN];
    int length = snprintf(record, sizeof(record), "DIR_SYNC %s\n", path);
    write(STDERR_FILENO, record, (size_t)length);
    const char *target = getenv("TEST_FAIL_SYNC_DIR");
    const char *ready = getenv("TEST_FAIL_SYNC_READY");
    const char *armed = getenv("TEST_FAIL_SYNC_ARMED");
    if (target && ready && armed && !strcmp(path, target) && !access(ready, F_OK) && !unlink(armed)) {
        length = snprintf(record, sizeof(record), "INJECT_EIO %s\n", path);
        write(STDERR_FILENO, record, (size_t)length);
        errno = EIO;
        return 1;
    }
    return 0;
}
static int traced_fcntl(int fd, int cmd, ...) {
    if (cmd == F_FULLFSYNC) {
        if (fail_sync(fd)) return -1;
        return fcntl(fd, cmd);
    }
    if (cmd == F_GETFD || cmd == F_GETFL || cmd == F_GETOWN) return fcntl(fd, cmd);
    va_list ap;
    va_start(ap, cmd);
    uintptr_t arg = va_arg(ap, uintptr_t);
    va_end(ap);
    return fcntl(fd, cmd, arg);
}
static int traced_fsync(int fd) {
    if (fail_sync(fd)) return -1;
    return fsync(fd);
}
#define INTERPOSE(replacement, original) \
 __attribute__((used)) static struct { const void *replacement; const void *original; } pair_##original \
 __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original };
INTERPOSE(traced_fcntl, fcntl)
INTERPOSE(traced_fsync, fsync)
