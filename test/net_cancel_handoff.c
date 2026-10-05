// Exercise the C owner of interpreter cancellation handoff. Real descriptors
// and the real scheduler/poller park; only resolver candidates and the syscall
// result preceding a park are controlled so a later candidate cannot hide it.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <sys/socket.h>
#include <netdb.h>
#include <errno.h>
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int controlled_lookup(const char*, const char*, const struct addrinfo*,
                              struct addrinfo**);
static void controlled_free(struct addrinfo*);
static int controlled_connect(int, const struct sockaddr*, socklen_t);
static ssize_t controlled_send(int, const void*, size_t, int,
                               const struct sockaddr*, socklen_t);
static ssize_t controlled_recv(int, void*, size_t, int);
#define getaddrinfo controlled_lookup
#define freeaddrinfo controlled_free
#define connect controlled_connect
#define sendto controlled_send
#define recv controlled_recv
#include "../runtime/beans_rt.c"
#undef getaddrinfo
#undef freeaddrinfo
#undef connect
#undef sendto
#undef recv

// The compiler normally supplies these class hooks. This C case owns no
// generated classes; runtime Error and Bytes values use their built-in shapes.
long long beans_class_parents[1] = {-1};
long long beans_deinit_sel = -1;

static int lookups, frees, attempts, last_connect_fd, receives, delivered;
static int op, handoff;
static int pair_fd[2];
static int returned;
static BeansFiber* target;
static char* host;
static BList* payload;

static int controlled_lookup(const char* name, const char* service,
                              const struct addrinfo* hint,
                              struct addrinfo** result) {
    (void)name; (void)service;
    struct addrinfo* a = calloc(1, sizeof *a);
    struct addrinfo* b = calloc(1, sizeof *b);
    assert(a && b);
    a->ai_family = b->ai_family = AF_INET;
    a->ai_socktype = b->ai_socktype = hint->ai_socktype;
    a->ai_next = b;
    *result = a;
    lookups++;
    return 0;
}
static void controlled_free(struct addrinfo* list) {
    assert(list && list->ai_next && !list->ai_next->ai_next);
    free(list->ai_next);
    free(list);
    frees++;
}
static int controlled_connect(int fd, const struct sockaddr* at, socklen_t n) {
    (void)at; (void)n;
    attempts++;
    last_connect_fd = fd;
    errno = EINPROGRESS;
    return -1;
}
static ssize_t controlled_send(int fd, const void* data, size_t n, int flags,
                               const struct sockaddr* at, socklen_t size) {
    (void)fd; (void)data; (void)n; (void)flags; (void)at; (void)size;
    attempts++;
    // A retry after handoff would succeed and transmit, exactly the outcome
    // cancellation must stop before the walker skips constructing a result.
    if (attempts > 1) return (ssize_t)n;
    errno = EAGAIN;
    return -1;
}
static ssize_t controlled_recv(int fd, void* buffer, size_t n, int flags) {
    if (op < 2) return recv(fd, buffer, n, flags);
    receives++;
    // One owned many-read buffer receives a prefix, grows for its next chunk,
    // then parks. This proves the partial-buffer path without sleep timing.
    assert(n == 8192);
    if (receives == 1) { memcpy(buffer, "prefix", 6); return 6; }
    errno = EAGAIN;
    return -1;
}
static void cancelled(void* argument) { (void)argument; delivered++; }
static void work(void* argument) {
    (void)argument;
    // A non-null argument distinguishes an installed handler from clearing it.
    if (handoff) beans_fiber_set_cancel_handler(cancelled, &delivered);
    BRes result;
    if (op == 0) result = beans_net_connect(host, 1, 5000);
    else if (op == 1) result = beans_net_send_to(pair_fd[0], payload, host, 1);
    else if (op == 2) result = beans_net_recv_exact(pair_fd[0], 65536);
    else result = beans_net_recv_to_end(pair_fd[0], 65536);
    returned++;
    if (op < 2) assert(result.val == 0 && result.err == NULL);
    if (result.err) beans_release(result.err);
    beans_fiber_set_cancel_handler(NULL, NULL);
    beans_fiber_mask_cancel(0);
}
static void cancel_and_join(void* argument) {
    (void)argument;
    beans_fiber_cancel(target);
    char message[32];
    int status = beans_fiber_join(target, message, sizeof message);
    assert(status == (handoff ? BEANS_FIBER_OK : BEANS_FIBER_CANCELLED));
}
int main(void) {
    host = beans_str_from_raw("controlled", 10);
    payload = bytes_mk(1);
    for (handoff = 0; handoff < 2; handoff++) {
        for (op = 0; op < 4; op++) {
            lookups = frees = attempts = receives = delivered = returned = 0;
            last_connect_fd = -1;
            if (op == 1) {
                pair_fd[0] = socket(AF_INET, SOCK_DGRAM, 0);
                pair_fd[1] = -1;
                assert(pair_fd[0] >= 0);
            } else if (op >= 2) {
                assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair_fd) == 0);
            }
            unsigned long long allocated = arc_allocations;
            unsigned long long released = arc_freed_shells;
            BeansWorker* worker = beans_worker_new();
            target = beans_fiber_spawn(worker, work, NULL, "net-owner", 0);
            BeansFiber* cancel = beans_fiber_spawn(worker, cancel_and_join,
                                                  NULL, "cancel", 0);
            beans_fiber_forget(cancel);
            beans_worker_run(worker);
            assert(delivered == handoff && returned == handoff);
            if (op < 2) assert(lookups == 1 && frees == 1 && attempts == 1);
            else assert(receives == 2);
            assert(arc_allocations - allocated == arc_freed_shells - released);
            if (op == 0) {
                errno = 0;
                assert(fcntl(last_connect_fd, F_GETFD) == -1 && errno == EBADF);
            } else {
                // The send/receive entries borrow their descriptor.
                assert(fcntl(pair_fd[0], F_GETFD) >= 0);
                close(pair_fd[0]);
                if (pair_fd[1] >= 0) close(pair_fd[1]);
            }
            beans_worker_free(worker);
        }
    }
    beans_release(payload);
    beans_release(host);
    puts("net cancellation: one resolver attempt, resolver freed, fd ownership, partial buffer freed");
    return 0;
}
