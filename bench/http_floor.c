// http_floor.c — the smallest correct HTTP/1.1 keep-alive server this kernel
// allows: one thread, one kqueue, one read per readiness event, one writev
// per response, no parsing beyond the end-of-head scan.
//
// It exists to measure the machine, not to be a server. Whatever req/s and
// CPU per request this reaches on a route is the floor every real server on
// this box sits above. A performance target below it is not a target, and a
// req/s number published without it cannot be read: it is impossible to tell
// a server that is 30% off the machine from one that is 3% off.
//
// bench/espresso_ledger.sh runs this interleaved with the servers under test
// and prints its number on every row.
//
//   http_floor json     <port> [sndbuf]            27-byte JSON body
//   http_floor bytes    <port> [sndbuf] [nbytes]   synthetic body, default 1 MiB
//   http_floor file     <port> <sndbuf> <path>     the benchmark's exact bytes
//   http_floor echo     <port> <sndbuf> <path>     consume a POST body, reply <path>
//
// `static1m` is accepted as an alias for `bytes` so older invocations still
// work. Prefer `file`: it serves a body byte-identical to the one the servers
// under test return, which is what makes the comparison a comparison.
//
// `echo` reads the request body the client sends (Content-Length only, which
// is what the benchmark sends) and throws it away before replying. It does not
// parse it. That makes it the I/O floor for a POST route — the kernel cost of
// getting 101 KB in and a small answer out — and nothing more: a real server
// still has to decode what it read, and this one never does.
//
// Headers match the benchmark's three exactly (Content-Type, Content-Length,
// Date) so the wire bytes are comparable; the Date is frozen because this
// server does not keep time.
//
// kqueue, so macOS and the BSDs. That is deliberate rather than unfinished:
// the benchmark this rules is a macOS one, and the multi-core Linux table it
// would otherwise serve was dropped as untrustworthy on the hardware to hand.
// Porting it means an epoll arm in flush_conn/on_read and the event loop —
// about forty lines — and the day a Linux box is in the picture, that is the
// change to make.
#include <sys/socket.h>
#include <sys/event.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <signal.h>

#define MAXFD 16384
typedef struct {
    char in[8192];
    int inlen;
    long body_left;  // request-body bytes still to consume (echo mode)
    size_t outoff;   // bytes of the response in progress already written
    int pending;     // responses owed, the one in progress included
    int wwatch;
} Conn;
static Conn* conns[MAXFD];
static const char* HEAD; static size_t HEADLEN;
static const char* BODY; static size_t BODYLEN;
static int kq;
static int echo_mode;

// Content-Length out of a request head, or 0 when it has none. Case-insensitive
// because the header name is, and bounded by the head we already framed.
static long content_length(const char* head, size_t n) {
    static const char* K = "content-length:";
    const size_t KN = 15;
    if (n < KN) return 0;
    for (size_t i = 0; i + KN <= n; i++) {
        size_t j = 0;
        while (j < KN) {
            char c = head[i + j];
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            if (c != K[j]) break;
            j++;
        }
        if (j < KN) continue;
        const char* v = head + i + KN;
        while (v < head + n && (*v == ' ' || *v == '\t')) v++;
        long len = 0;
        while (v < head + n && *v >= '0' && *v <= '9') {
            if (len > 100000000L) return len;   // absurd; stop before overflow
            len = len * 10 + (*v - '0');
            v++;
        }
        return len;
    }
    return 0;
}

static void nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// Writes as much of the owed responses as the socket takes. 0 = fine (may
// still owe, write filter armed), -1 = close the connection.
static int flush_conn(int fd, Conn* c) {
    while (c->pending > 0) {
        struct iovec iov[2];
        int n = 0;
        size_t off = c->outoff;
        if (off < HEADLEN) {
            iov[n].iov_base = (void*)(HEAD + off); iov[n].iov_len = HEADLEN - off; n++;
            iov[n].iov_base = (void*)BODY;         iov[n].iov_len = BODYLEN;       n++;
        } else {
            size_t boff = off - HEADLEN;
            iov[n].iov_base = (void*)(BODY + boff); iov[n].iov_len = BODYLEN - boff; n++;
        }
        ssize_t wrote = writev(fd, iov, n);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (!c->wwatch) {
                    struct kevent ev;
                    EV_SET(&ev, fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, 0, 0, NULL);
                    kevent(kq, &ev, 1, NULL, 0, NULL);
                    c->wwatch = 1;
                }
                return 0;
            }
            return -1;
        }
        c->outoff += (size_t)wrote;
        if (c->outoff >= HEADLEN + BODYLEN) { c->outoff = 0; c->pending--; }
    }
    return 0;
}

// One read per readiness event (level-triggered: leftover data re-fires).
static int on_read(int fd, Conn* c) {
    ssize_t got;
    do {
        got = read(fd, c->in + c->inlen, sizeof(c->in) - c->inlen);
    } while (got < 0 && errno == EINTR);
    if (got == 0) return -1;
    if (got < 0) return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
    c->inlen += (int)got;
    int start = 0;
    for (;;) {
        // A request is owed a response only once its body is in, so a POST
        // never gets answered before the client has finished sending.
        if (c->body_left > 0) {
            long have = c->inlen - start;
            long take = have < c->body_left ? have : c->body_left;
            start += (int)take;
            c->body_left -= take;
            if (c->body_left > 0) break;
            c->pending++;
            continue;
        }
        char* end = memmem(c->in + start, (size_t)(c->inlen - start), "\r\n\r\n", 4);
        if (!end) break;
        size_t headlen = (size_t)(end - (c->in + start)) + 4;
        long clen = echo_mode ? content_length(c->in + start, headlen) : 0;
        start += (int)headlen;
        if (clen > 0) { c->body_left = clen; continue; }
        c->pending++;
    }
    if (start > 0) {
        memmove(c->in, c->in + start, (size_t)(c->inlen - start));
        c->inlen -= start;
    }
    // A head that does not fit the buffer is a client this ruler does not
    // serve. A body never lands here: it is consumed above, not buffered.
    if (c->inlen == (int)sizeof(c->in)) return -1;
    return flush_conn(fd, c);
}

int main(int argc, char** argv) {
    const char* mode = argc > 1 ? argv[1] : "json";
    int port = argc > 2 ? atoi(argv[2]) : 9090;
    int sndbuf = argc > 3 ? atoi(argv[3]) : 0;
    // argv[4] is a byte count in `bytes` mode and a path in `file` mode.
    size_t body_bytes = argc > 4 ? (size_t)atol(argv[4]) : (1u << 20);
    const char* body_path = argc > 4 ? argv[4] : NULL;
    const char* body_type = argc > 5 ? argv[5] : "text/plain; charset=utf-8";
    signal(SIGPIPE, SIG_IGN);

    const char* type;
    if (strcmp(mode, "json") == 0) {
        BODY = "{\"message\":\"Hello, World!\"}";
        BODYLEN = strlen(BODY);
        type = "application/json; charset=utf-8";
    } else if (strcmp(mode, "file") == 0 || strcmp(mode, "echo") == 0) {
        if (strcmp(mode, "echo") == 0) {
            echo_mode = 1;
            if (argc <= 5) body_type = "application/json; charset=utf-8";
        }
        if (!body_path) { fprintf(stderr, "file mode needs a path\n"); return 2; }
        FILE* f = fopen(body_path, "rb");
        if (!f) { perror(body_path); return 2; }
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        if (n < 0) { perror("ftell"); return 2; }
        fseek(f, 0, SEEK_SET);
        char* b = malloc((size_t)n);
        if (!b) { fprintf(stderr, "out of memory for %ld bytes\n", n); return 2; }
        if (fread(b, 1, (size_t)n, f) != (size_t)n) {
            fprintf(stderr, "short read of %s\n", body_path); return 2;
        }
        fclose(f);
        BODY = b; BODYLEN = (size_t)n;
        type = body_type;
    } else {
        // The seed is copied 64 bytes at a time, so the buffer is rounded up
        // to a whole seed and only body_bytes of it are ever sent. Writing the
        // tail with a full memcpy into an exact-size malloc overruns the heap
        // for any size that is not a multiple of 64 — 247 KB is not.
        size_t n = body_bytes;
        size_t cap = (n + 63) & ~(size_t)63;
        char* b = malloc(cap);
        if (!b) { fprintf(stderr, "out of memory for %zu bytes\n", cap); return 2; }
        const char* seed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-\n";
        for (size_t i = 0; i < cap; i += 64) memcpy(b + i, seed, 64);
        BODY = b; BODYLEN = n;
        type = "text/plain; charset=utf-8";
    }
    static char headbuf[512];
    HEADLEN = (size_t)snprintf(headbuf, sizeof headbuf,
        "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "Date: Sat, 06 Sep 2026 02:30:00 GMT\r\n\r\n", type, BODYLEN);
    HEAD = headbuf;

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr*)&a, sizeof a) < 0) { perror("bind"); return 1; }
    listen(ls, 512);
    nonblock(ls);

    kq = kqueue();
    struct kevent ev;
    EV_SET(&ev, ls, EVFILT_READ, EV_ADD, 0, 0, NULL);
    kevent(kq, &ev, 1, NULL, 0, NULL);
    fprintf(stderr, "floor %s listening on %d sndbuf=%d\n", mode, port, sndbuf);

    struct kevent evs[256];
    for (;;) {
        int n = kevent(kq, NULL, 0, evs, 256, NULL);
        for (int i = 0; i < n; i++) {
            int fd = (int)evs[i].ident;
            if (fd == ls) {
                for (;;) {
                    int c = accept(ls, NULL, NULL);
                    if (c < 0) break;
                    if (c >= MAXFD) { close(c); continue; }
                    nonblock(c);
                    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    if (sndbuf > 0) setsockopt(c, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf);
                    conns[c] = calloc(1, sizeof(Conn));
                    EV_SET(&ev, c, EVFILT_READ, EV_ADD, 0, 0, NULL);
                    kevent(kq, &ev, 1, NULL, 0, NULL);
                }
                continue;
            }
            Conn* c = conns[fd];
            if (!c) continue;
            int rc;
            if (evs[i].filter == EVFILT_WRITE) { c->wwatch = 0; rc = flush_conn(fd, c); }
            else rc = on_read(fd, c);
            if (rc < 0) { close(fd); free(c); conns[fd] = NULL; }
        }
    }
}
