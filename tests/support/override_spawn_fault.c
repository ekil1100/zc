/* Test-only spawn-boundary fault injection, not a reproduction of Linux ETXTBSY. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <dlfcn.h>
#endif

static unsigned attempts;
static uint64_t started_ns;
/* libc may implement posix_spawnp by calling posix_spawn. Count API attempts,
 * not nested forwarding through both symbols. This is never loader-time IO. */
static _Thread_local unsigned forwarding;

static void fail(const char *operation) {
    perror(operation);
    _exit(90);
}

/* Only the isolated helper's temporary executable is eligible. */
static int injected_error(const char *path) {
    if (forwarding) return 0;
    const char *tmp = getenv("TMPDIR");
    const char *log = getenv("ZC_SPAWN_LOG");
    if (!tmp || !log) return 0;
    size_t length = strlen(tmp);
    if (strncmp(path, tmp, length) || path[length] != '/') return 0;

    const char *expected = getenv("ZC_SPAWN_EXPECTED");
    const char *count = getenv("ZC_SPAWN_FAILURES");
    const char *kind = getenv("ZC_SPAWN_ERROR");
    if (!expected || !count || !kind) fail("missing spawn injection scope");
    /* Compare every attempted executable with the independently frozen fixture. */
    FILE *actual = fopen(path, "rb");
    FILE *frozen = fopen(expected, "rb");
    if (!actual || !frozen) fail("open frozen script");
    int a, b;
    do {
        a = fgetc(actual);
        b = fgetc(frozen);
        if (a != b) fail("temporary script bytes changed");
    } while (a != EOF);
    if (ferror(actual) || ferror(frozen)) fail("read frozen script");
    if (fclose(actual) || fclose(frozen)) fail("close frozen script");

    ++attempts;
    long failures = strtol(count, NULL, 10);
    int busy = failures < 0 || attempts <= (unsigned long)failures;
    const char *duration = getenv("ZC_SPAWN_BUSY_MS");
    if (duration && strtoul(duration, NULL, 10) != 0) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now)) fail("read monotonic clock");
        uint64_t now_ns = (uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec;
        if (!started_ns) started_ns = now_ns;
        busy = now_ns - started_ns < strtoull(duration, NULL, 10) * 1000000;
    }
    int error = busy ? (!strcmp(kind, "EACCES") ? EACCES : ETXTBSY) : 0;
    const char *action = !error ? "FORWARD" : error == EACCES ? "INJECT_EACCES" : "INJECT_ETXTBSY";
    FILE *record = fopen(log, "a");
    if (!record || fprintf(record, "%u %s %s\n", attempts, action, path) < 0 ||
        fclose(record)) fail("write spawn marker");
    return error;
}

#ifdef __APPLE__
static int captured_spawn(pid_t *pid, const char *path,
                          const posix_spawn_file_actions_t *actions,
                          const posix_spawnattr_t *attr,
                          char *const argv[], char *const envp[]) {
    int saved_errno = errno;
    int error = injected_error(path);
    errno = saved_errno;
    if (error) return error;
    ++forwarding;
    int result = posix_spawn(pid, path, actions, attr, argv, envp);
    --forwarding;
    return result;
}
static int captured_spawnp(pid_t *pid, const char *path,
                           const posix_spawn_file_actions_t *actions,
                           const posix_spawnattr_t *attr,
                           char *const argv[], char *const envp[]) {
    int saved_errno = errno;
    int error = injected_error(path);
    errno = saved_errno;
    if (error) return error;
    ++forwarding;
    int result = posix_spawnp(pid, path, actions, attr, argv, envp);
    --forwarding;
    return result;
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } pair_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original }
INTERPOSE(captured_spawn, posix_spawn);
INTERPOSE(captured_spawnp, posix_spawnp);
#else
#define SPAWN_WRAPPER(name) \
    int name(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, \
             const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) { \
        int saved_errno = errno; \
        int error = injected_error(path); \
        errno = saved_errno; \
        if (error) return error; \
        int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *, \
                    const posix_spawnattr_t *, char *const[], char *const[]) = dlsym(RTLD_NEXT, #name); \
        if (!real) fail("resolve " #name); \
        ++forwarding; \
        int result = real(pid, path, actions, attr, argv, envp); \
        --forwarding; \
        return result; \
    }
SPAWN_WRAPPER(posix_spawn)
SPAWN_WRAPPER(posix_spawnp)
#endif
