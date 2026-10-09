// Compiler roots must return to their caller after nested entry and child waits.
#include "../runtime/beans_fiber.h"
#include <assert.h>
#include <stdio.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dirent.h>
#include <errno.h>
#include <sys/resource.h>
#include <unistd.h>

static int fd_count(void) {
    DIR* directory = opendir("/proc/self/fd");
    if (!directory) directory = opendir("/dev/fd");
    assert(directory);
    int count = 0;
    while (readdir(directory)) count++;
    closedir(directory);
    return count;
}
#endif

static void child(void* context) {
    int* steps = context;
    assert((*steps)++ == 0);
    beans_fiber_yield();
    assert((*steps)++ == 1);
}

static void nested(void* context) {
    assert(beans_fiber_is_root(beans_fiber_current()));
    assert((*(int*)context)++ == 2);
}

static void root(void* context) {
    assert(beans_fiber_is_root(beans_fiber_current()));
#if !defined(_WIN32)
    int baseline = fd_count();
    if (beans_fiber_netpoll()) {
        int descriptors[2];
        assert(pipe(descriptors) == 0);
        assert(beans_fiber_wait_io(descriptors[0], 0, 1) == 1);
        close(descriptors[0]);
        close(descriptors[1]);
        assert(fd_count() == baseline);
    }
#endif
    BeansFiber* task = beans_fiber_spawn(beans_worker_current(), child,
                                        context, "child", 0);
    assert(task);
    assert(beans_fiber_join(task, NULL, 0) == BEANS_FIBER_OK);
    assert(beans_fiber_run_root(nested, context, 0) == 0);
}

static void check_root(void) {
#if !defined(_WIN32)
    int baseline = fd_count();
#endif
    for (int attempt = 0; attempt < 2; attempt++) {
        int steps = 0;
        assert(beans_fiber_run_root(root, &steps, 8 * 1024 * 1024) == 0);
        assert(steps == 3);
        assert(beans_worker_current() == NULL);
#if !defined(_WIN32)
        assert(fd_count() == baseline);
#endif
    }
}

#if !defined(_WIN32)
static void mark_entry(void* context) { (*(int*)context)++; }

static void check_poller_failure(void) {
    if (!beans_fiber_netpoll()) return;
    int baseline = fd_count();
    struct rlimit saved;
    assert(getrlimit(RLIMIT_NOFILE, &saved) == 0);
    struct rlimit exhausted = saved;
    exhausted.rlim_cur = 0;
    assert(setrlimit(RLIMIT_NOFILE, &exhausted) == 0);
    int entered = 0;
    int status = beans_fiber_run_root(mark_entry, &entered, 8 * 1024 * 1024);
    assert(setrlimit(RLIMIT_NOFILE, &saved) == 0);
    assert(status == EMFILE && entered == 0);
    assert(beans_worker_current() == NULL);
    assert(fd_count() == baseline);
#if defined(__linux__)
    exhausted.rlim_cur = saved.rlim_cur < 64 ? saved.rlim_cur : 64;
    assert(setrlimit(RLIMIT_NOFILE, &exhausted) == 0);
    int held[64], count = 0, descriptor;
    while ((descriptor = dup(STDOUT_FILENO)) >= 0) held[count++] = descriptor;
    assert(count > 0);
    close(held[--count]);
    status = beans_fiber_run_root(mark_entry, &entered, 8 * 1024 * 1024);
    while (count) close(held[--count]);
    assert(setrlimit(RLIMIT_NOFILE, &saved) == 0);
    assert(status == EMFILE && entered == 0);
    assert(beans_worker_current() == NULL);
    assert(fd_count() == baseline);
#endif
}
#endif

int main(void) {
    check_root();
#if !defined(_WIN32)
    check_poller_failure();
#endif
#if defined(_WIN32)
    assert(!IsThreadAFiber());
    assert(ConvertThreadToFiber(NULL));
    check_root();
    assert(IsThreadAFiber());
    assert(ConvertFiberToThread());
#endif
    puts("ok compiler root returns and preserves its caller");
    return 0;
}
