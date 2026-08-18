// WebSocket framing for std.websocket — wslay behind a byte-pump ABI.
//
// wslay does framing, masking and fragmentation and no IO of its own, so
// this bridge gives it memory buffers instead of sockets: ciphertext-free
// bytes in from the transport, frames out to the transport, and completed
// messages accumulated into an event queue the Beans side drains. Every
// wslay callback is a C static reading and writing those buffers — nothing
// calls back into Beans, so there is no stored-callback machinery and no
// thread contract to get wrong.
//
// RFC 6455 requires text payloads to be valid UTF-8, checked on the
// ASSEMBLED message rather than per frame, because a code point may straddle
// a fragment boundary. The check is written here against Unicode Table 3-7
// rather than borrowed from the vendored simdutf: that copy is built with
// SIMDUTF_FEATURE_UTF8 off (std.encoding.base64 needs only the base64 lane),
// so reusing it would mean either compiling simdutf a second time —
// duplicate symbols the moment a program uses both packages — or making
// every base64 user carry UTF-8 tables. Autobahn's section 6 is the gate
// either way, and it is a far harder examiner than provenance.
//
// Message event encoding, little-endian, one per completed message:
//   [u8 opcode][u64 len][payload]
// opcodes: 1 text, 2 binary, 8 close, 9 ping, 10 pong. A close event's
// payload is the two-byte code (big-endian, RFC 6455 order) followed by the
// reason text, or empty when the peer sent no body.

// rand_s exists only under _CRT_RAND_S, and the knob has to precede every
// include -- beans_net_common.h already pulls in <stdlib.h>.
#if defined(_WIN32)
#define _CRT_RAND_S 1
#endif

#include "beans_net_common.h"

extern "C" {
#include "wslay/wslay.h"
}

#include <stdio.h>

#if !defined(_WIN32) && !defined(__APPLE__) && !defined(__FreeBSD__) && \
    !defined(__OpenBSD__) && !defined(__NetBSD__)
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#endif

// Unicode Table 3-7, "Well-Formed UTF-8 Byte Sequences", exactly: the ranges
// below are what make overlong encodings, surrogates (U+D800..U+DFFF) and
// anything past U+10FFFF ill-formed rather than merely unusual.
static bool ws_valid_utf8(const uint8_t* data, size_t len) {
    size_t i = 0;
    while (i < len) {
        uint8_t b = data[i];
        if (b <= 0x7f) { i += 1; continue; }
        size_t need;
        uint8_t lo, hi;           // allowed range of the SECOND byte
        if (b >= 0xc2 && b <= 0xdf)      { need = 2; lo = 0x80; hi = 0xbf; }
        else if (b == 0xe0)              { need = 3; lo = 0xa0; hi = 0xbf; }
        else if (b >= 0xe1 && b <= 0xec) { need = 3; lo = 0x80; hi = 0xbf; }
        else if (b == 0xed)              { need = 3; lo = 0x80; hi = 0x9f; }
        else if (b >= 0xee && b <= 0xef) { need = 3; lo = 0x80; hi = 0xbf; }
        else if (b == 0xf0)              { need = 4; lo = 0x90; hi = 0xbf; }
        else if (b >= 0xf1 && b <= 0xf3) { need = 4; lo = 0x80; hi = 0xbf; }
        else if (b == 0xf4)              { need = 4; lo = 0x80; hi = 0x8f; }
        else return false;        // 0x80..0xc1 and 0xf5..0xff never lead
        if (i + need > len) return false;
        if (data[i + 1] < lo || data[i + 1] > hi) return false;
        for (size_t k = 2; k < need; k++) {
            if (data[i + k] < 0x80 || data[i + k] > 0xbf) return false;
        }
        i += need;
    }
    return true;
}

enum {
    BEANS_WS_PROTOCOL = 120,   // wslay rejected the frame stream
    BEANS_WS_TOO_LARGE = 121,  // message exceeded the declared limit
    BEANS_WS_UTF8 = 122,       // text message was not valid UTF-8
    BEANS_WS_CLOSED = 123,     // context already closed
};

// The same growable queue the TLS bridge uses, kept local so the two
// bridges stay independent translation units.
// Plain data with helpers: no constructors, no virtuals, so one calloc
// makes a valid object and this bridge links with the C driver like every
// other one — no C++ runtime, exactly the rule the encoding bridges follow.
struct WsBuf {
    uint8_t* data;
    size_t len;
    size_t cap;
    size_t head;

    bool reserve(size_t more) {
        if (head > 0 && head == len) { head = 0; len = 0; }
        if (len + more <= cap) return true;
        if (head > 0) {
            memmove(data, data + head, len - head);
            len -= head;
            head = 0;
            if (len + more <= cap) return true;
        }
        size_t want = cap ? cap * 2 : 4096;
        while (want < len + more) want *= 2;
        uint8_t* grown = (uint8_t*)realloc(data, want);
        if (!grown) return false;
        data = grown;
        cap = want;
        return true;
    }

    bool push(const uint8_t* src, size_t n) {
        if (!reserve(n)) return false;
        memcpy(data + len, src, n);
        len += n;
        return true;
    }

    size_t available() const { return len - head; }

    size_t take(uint8_t* dst, size_t want) {
        size_t have = len - head;
        size_t n = have < want ? have : want;
        if (n) memcpy(dst, data + head, n);
        head += n;
        if (head == len) { head = 0; len = 0; }
        return n;
    }
};

struct WsSession {
    wslay_event_context_ptr ctx;
    WsBuf incoming;   // bytes from the transport, into wslay
    WsBuf outgoing;   // frames from wslay, to the transport
    WsBuf events;     // completed messages, for the Beans side
    uint64_t max_message;
    int is_server;
    int failure;      // sticky status once something goes wrong
    uint64_t magic;
};

static const uint64_t BEANS_WS_MAGIC = 0x62656e7377733031ULL;

static WsSession* ws_of(long long handle) {
    WsSession* s = (WsSession*)(intptr_t)handle;
    if (!s || s->magic != BEANS_WS_MAGIC) return nullptr;
    return s;
}

static void ws_put_u64(uint8_t* at, uint64_t value) {
    for (int i = 0; i < 8; i++) at[i] = (uint8_t)(value >> (i * 8));
}

// ---- wslay callbacks: buffers only, never Beans -----------------------------

static ssize_t ws_recv_cb(wslay_event_context_ptr ctx, uint8_t* buf, size_t len,
                          int flags, void* user) {
    (void)ctx; (void)flags;
    WsSession* s = (WsSession*)user;
    size_t got = s->incoming.take(buf, len);
    if (got == 0) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    }
    return (ssize_t)got;
}

static ssize_t ws_send_cb(wslay_event_context_ptr ctx, const uint8_t* data,
                          size_t len, int flags, void* user) {
    (void)ctx; (void)flags;
    WsSession* s = (WsSession*)user;
    if (!s->outgoing.push(data, len)) {
        wslay_event_set_error(ctx, WSLAY_ERR_NOMEM);
        return -1;
    }
    return (ssize_t)len;
}

// Client frames must be masked with unpredictable keys. The OS CSPRNG is the
// only acceptable source, reached the same way std.random does -- per
// platform, not through /dev/urandom alone. Getting this wrong is not subtle:
// with no Windows path at all, wslay cannot mask a frame, and RFC 6455
// requires every client frame to be masked, so client sends fail outright.
static int ws_genmask_cb(wslay_event_context_ptr ctx, uint8_t* buf, size_t len,
                         void* user) {
    (void)ctx; (void)user;
#if defined(_WIN32)
    size_t done = 0;
    while (done < len) {
        unsigned int word = 0;
        if (rand_s(&word) != 0) return -1;
        size_t take = len - done < sizeof word ? len - done : sizeof word;
        memcpy(buf + done, &word, take);
        done += take;
    }
    return 0;
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    arc4random_buf(buf, len);
    return 0;
#else
    size_t done = 0;
    while (done < len) {
        long got = syscall(SYS_getrandom, buf + done, len - done, 0);
        if (got < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (got == 0) break;
        done += (size_t)got;
    }
    if (done == len) return 0;
    // Older kernels and seccomp sandboxes without getrandom still have the
    // device; a single failed read is fatal rather than falling back to
    // anything predictable.
    FILE* urandom = fopen("/dev/urandom", "rb");
    if (!urandom) return -1;
    size_t got = fread(buf + done, 1, len - done, urandom);
    fclose(urandom);
    return got == len - done ? 0 : -1;
#endif
}

static void ws_on_msg_cb(wslay_event_context_ptr ctx,
                         const struct wslay_event_on_msg_recv_arg* arg,
                         void* user) {
    (void)ctx;
    WsSession* s = (WsSession*)user;
    if (arg->msg_length > s->max_message) {
        s->failure = BEANS_WS_TOO_LARGE;
        return;
    }
    // The assembled-message UTF-8 check RFC 6455 requires.
    if (arg->opcode == WSLAY_TEXT_FRAME && arg->msg_length > 0) {
        if (!ws_valid_utf8(arg->msg, (size_t)arg->msg_length)) {
            s->failure = BEANS_WS_UTF8;
            return;
        }
    }
    uint8_t header[1 + 8];
    header[0] = (uint8_t)arg->opcode;
    ws_put_u64(header + 1, (uint64_t)arg->msg_length);
    if (!s->events.push(header, sizeof header) ||
        (arg->msg_length &&
         !s->events.push(arg->msg, (size_t)arg->msg_length))) {
        s->failure = BEANS_NET_ERR_MEMORY;
    }
}

// ---- entry points -------------------------------------------------------------

// req: [0] is_server, [1] max message bytes (0 keeps the default).
BEANS_NET_API long long beans_ws_new(const uint64_t* req) {
    if (!req) return 0;
    WsSession* s = (WsSession*)calloc(1, sizeof(WsSession));
    if (!s) return 0;
    s->max_message = 8 * 1024 * 1024;
    s->is_server = (int)beans_net_word(req, 0);
    uint64_t limit = beans_net_word(req, 1);
    if (limit > 0) s->max_message = limit;

    struct wslay_event_callbacks callbacks;
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.recv_callback = ws_recv_cb;
    callbacks.send_callback = ws_send_cb;
    callbacks.genmask_callback = ws_genmask_cb;
    callbacks.on_msg_recv_callback = ws_on_msg_cb;

    int rc = s->is_server
        ? wslay_event_context_server_init(&s->ctx, &callbacks, s)
        : wslay_event_context_client_init(&s->ctx, &callbacks, s);
    if (rc != 0) {
        free(s);
        return 0;
    }
    wslay_event_config_set_max_recv_msg_length(s->ctx, s->max_message);
    s->magic = BEANS_WS_MAGIC;
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_ws_free(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->ctx) wslay_event_context_free(s->ctx);
    free(s->incoming.data);
    free(s->outgoing.data);
    free(s->events.data);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

// Hands the framer bytes that arrived, then runs one receive pass. Completed
// messages land in the event queue; frames the framer wants to send (a pong,
// a close echo) land in the outgoing queue.
BEANS_NET_API long long beans_ws_feed(long long handle, const uint8_t* data,
                                      const uint64_t* req) {
    WsSession* s = ws_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len > 0) {
        if (!data) return BEANS_NET_ERR_INVALID;
        if (!s->incoming.push(data, (size_t)len)) return BEANS_NET_ERR_MEMORY;
    }
    if (wslay_event_recv(s->ctx) != 0) {
        return s->failure ? s->failure : BEANS_WS_PROTOCOL;
    }
    if (s->failure) return s->failure;
    // A received close or queued pong needs flushing before the caller can
    // see it on the wire.
    if (wslay_event_send(s->ctx) != 0) return BEANS_WS_PROTOCOL;
    return s->failure ? s->failure : BEANS_NET_OK;
}

// Queues one message. opcode: 1 text, 2 binary, 9 ping, 10 pong.
// req: [0] opcode, [1] payload length.
BEANS_NET_API long long beans_ws_queue(long long handle, const uint8_t* data,
                                       const uint64_t* req) {
    WsSession* s = ws_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t opcode = beans_net_word(req, 0);
    uint64_t len = beans_net_word(req, 1);
    if (len > 0 && !data) return BEANS_NET_ERR_INVALID;
    struct wslay_event_msg msg;
    msg.opcode = (uint8_t)opcode;
    msg.msg = data;
    msg.msg_length = (size_t)len;
    if (wslay_event_queue_msg(s->ctx, &msg) != 0) return BEANS_WS_PROTOCOL;
    if (wslay_event_send(s->ctx) != 0) return BEANS_WS_PROTOCOL;
    return BEANS_NET_OK;
}

// Queues a close frame with a status code and reason.
// req: [0] status code, [1] reason length.
BEANS_NET_API long long beans_ws_close(long long handle, const uint8_t* reason,
                                       const uint64_t* req) {
    WsSession* s = ws_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t code = beans_net_word(req, 0);
    uint64_t len = beans_net_word(req, 1);
    // Same guard beans_ws_queue carries: a length with no bytes behind it
    // would have wslay copy from a null pointer.
    if (len > 0 && !reason) return BEANS_NET_ERR_INVALID;
    if (wslay_event_queue_close(s->ctx, (uint16_t)code, reason, (size_t)len) != 0)
        return BEANS_WS_PROTOCOL;
    if (wslay_event_send(s->ctx) != 0) return BEANS_WS_PROTOCOL;
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_ws_outgoing_size(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return -1;
    return (long long)s->outgoing.available();
}

BEANS_NET_API long long beans_ws_pull_outgoing(long long handle, uint8_t* out,
                                               const uint64_t* req) {
    WsSession* s = ws_of(handle);
    if (!s || !out || !req) return -1;
    return (long long)s->outgoing.take(out, (size_t)beans_net_word(req, 0));
}

BEANS_NET_API long long beans_ws_events_size(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return -1;
    return (long long)s->events.available();
}

BEANS_NET_API long long beans_ws_take_events(long long handle, uint8_t* out,
                                             const uint64_t* req) {
    WsSession* s = ws_of(handle);
    if (!s || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap < s->events.available()) return -1;
    return (long long)s->events.take(out, (size_t)cap);
}

// 1 while the peer has not closed and the framer still wants bytes.
BEANS_NET_API long long beans_ws_want_read(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return 0;
    return wslay_event_want_read(s->ctx) ? 1 : 0;
}

BEANS_NET_API long long beans_ws_want_write(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return 0;
    return wslay_event_want_write(s->ctx) ? 1 : 0;
}

// The close code THIS side sent, or 0. wslay answers a protocol violation
// by queueing the close frame itself and shutting its own read side rather
// than failing the call, so this is how the Beans layer learns that the
// framer ended the connection and why.
BEANS_NET_API long long beans_ws_close_code_sent(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return 0;
    return (long long)wslay_event_get_status_code_sent(s->ctx);
}

// The close code the peer sent, or 0 if none yet.
BEANS_NET_API long long beans_ws_peer_close_code(long long handle) {
    WsSession* s = ws_of(handle);
    if (!s) return 0;
    return (long long)wslay_event_get_status_code_received(s->ctx);
}

BEANS_NET_API long long beans_ws_available(void) { return 1; }
