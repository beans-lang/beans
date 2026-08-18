// HTTP/2 framing for std.http — nghttp2 behind a byte-pump ABI.
//
// nghttp2 owns frames, HPACK, flow control and stream state, and does no IO,
// which is exactly the shape this stack wants: bytes from the transport go
// in through mem_recv, bytes to send come out through mem_send, and every
// callback is a C static that appends to an event buffer the Beans side
// drains. Nothing calls back into Beans, so — as with the h1, ws and TLS
// bridges — there is no stored-callback machinery and no thread contract to
// get wrong. One session per connection, driven from one loop.
//
// Event encoding, little-endian:
//   [u8 1][u64 stream][u64 name_len][u64 value_len][name][value]  header
//   [u8 2][u64 stream][u64 flags]                                 headers done
//   [u8 3][u64 stream][u64 len][payload]                          data
//   [u8 4][u64 stream][u64 error_code]                            stream closed
//   [u8 5][u64 stream][u64 len][payload]                          (reserved)
//   [u8 6][u64 last_stream][u64 error_code]                       goaway
//   [u8 7][u64 0][u64 0]                                          settings ack
// The `flags` word on headers-done carries 1 when the peer said end-of-stream.

#include "beans_net_common.h"

#include "nghttp2/nghttp2.h"

enum {
    BEANS_H2_EV_HEADER = 1,
    BEANS_H2_EV_HEADERS_DONE = 2,
    BEANS_H2_EV_DATA = 3,
    BEANS_H2_EV_STREAM_CLOSED = 4,
    BEANS_H2_EV_GOAWAY = 6,
    BEANS_H2_EV_SETTINGS_ACK = 7,
};

enum {
    BEANS_H2_PROTOCOL = 130,  // nghttp2 rejected the byte stream
    BEANS_H2_CLOSED = 131,    // the session is finished
};

typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
} beans_h2_buf;

static int beans_h2_buf_reserve(beans_h2_buf* b, size_t more) {
    if (b->len + more <= b->cap) return 1;
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + more) cap *= 2;
    uint8_t* grown = (uint8_t*)realloc(b->data, cap);
    if (!grown) return 0;
    b->data = grown;
    b->cap = cap;
    return 1;
}

static int beans_h2_buf_push(beans_h2_buf* b, const uint8_t* src, size_t n) {
    if (!beans_h2_buf_reserve(b, n)) return 0;
    if (n) memcpy(b->data + b->len, src, n);
    b->len += n;
    return 1;
}

typedef struct {
    nghttp2_session* session;
    beans_h2_buf events;
    // Response/request bodies the Beans side handed us, keyed by stream: one
    // pending body per stream is enough for request/response, and nghttp2
    // pulls from it through the read callback below.
    beans_h2_buf pending_body;
    size_t pending_offset;
    int32_t pending_stream;
    int is_server;
    int failed;
    uint64_t magic;
} beans_h2_session;

#define BEANS_H2_MAGIC 0x62656e7368320001ULL

static beans_h2_session* beans_h2_of(long long handle) {
    beans_h2_session* s = (beans_h2_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_H2_MAGIC) return NULL;
    return s;
}

static void beans_h2_put_u64(uint8_t* at, uint64_t value) {
    for (int i = 0; i < 8; i++) at[i] = (uint8_t)(value >> (i * 8));
}

static void beans_h2_event3(beans_h2_session* s, int type, uint64_t a,
                            uint64_t b) {
    uint8_t head[1 + 8 + 8];
    head[0] = (uint8_t)type;
    beans_h2_put_u64(head + 1, a);
    beans_h2_put_u64(head + 9, b);
    if (!beans_h2_buf_push(&s->events, head, sizeof head)) s->failed = 1;
}

// ---- nghttp2 callbacks: buffers only ---------------------------------------

static int beans_h2_on_header(nghttp2_session* session,
                              const nghttp2_frame* frame,
                              const uint8_t* name, size_t namelen,
                              const uint8_t* value, size_t valuelen,
                              uint8_t flags, void* user) {
    (void)session; (void)flags;
    beans_h2_session* s = (beans_h2_session*)user;
    uint8_t head[1 + 8 + 8 + 8];
    head[0] = BEANS_H2_EV_HEADER;
    beans_h2_put_u64(head + 1, (uint64_t)frame->hd.stream_id);
    beans_h2_put_u64(head + 9, (uint64_t)namelen);
    beans_h2_put_u64(head + 17, (uint64_t)valuelen);
    if (!beans_h2_buf_push(&s->events, head, sizeof head) ||
        !beans_h2_buf_push(&s->events, name, namelen) ||
        !beans_h2_buf_push(&s->events, value, valuelen)) {
        s->failed = 1;
    }
    return 0;
}

static int beans_h2_on_frame_recv(nghttp2_session* session,
                                  const nghttp2_frame* frame, void* user) {
    (void)session;
    beans_h2_session* s = (beans_h2_session*)user;
    if (frame->hd.type == NGHTTP2_HEADERS) {
        uint64_t flags = (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) ? 1 : 0;
        beans_h2_event3(s, BEANS_H2_EV_HEADERS_DONE,
                        (uint64_t)frame->hd.stream_id, flags);
    } else if (frame->hd.type == NGHTTP2_DATA) {
        if (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) {
            // An empty end-of-stream DATA frame still ends the message; the
            // Beans side learns it here rather than from a zero-length body.
            beans_h2_event3(s, BEANS_H2_EV_HEADERS_DONE,
                            (uint64_t)frame->hd.stream_id, 1);
        }
    } else if (frame->hd.type == NGHTTP2_GOAWAY) {
        beans_h2_event3(s, BEANS_H2_EV_GOAWAY,
                        (uint64_t)frame->goaway.last_stream_id,
                        (uint64_t)frame->goaway.error_code);
    } else if (frame->hd.type == NGHTTP2_SETTINGS &&
               (frame->hd.flags & NGHTTP2_FLAG_ACK)) {
        beans_h2_event3(s, BEANS_H2_EV_SETTINGS_ACK, 0, 0);
    }
    return 0;
}

static int beans_h2_on_data_chunk(nghttp2_session* session, uint8_t flags,
                                  int32_t stream_id, const uint8_t* data,
                                  size_t len, void* user) {
    (void)session; (void)flags;
    beans_h2_session* s = (beans_h2_session*)user;
    uint8_t head[1 + 8 + 8];
    head[0] = BEANS_H2_EV_DATA;
    beans_h2_put_u64(head + 1, (uint64_t)stream_id);
    beans_h2_put_u64(head + 9, (uint64_t)len);
    if (!beans_h2_buf_push(&s->events, head, sizeof head) ||
        !beans_h2_buf_push(&s->events, data, len)) {
        s->failed = 1;
    }
    return 0;
}

static int beans_h2_on_stream_close(nghttp2_session* session, int32_t stream_id,
                                    uint32_t error_code, void* user) {
    (void)session;
    beans_h2_session* s = (beans_h2_session*)user;
    beans_h2_event3(s, BEANS_H2_EV_STREAM_CLOSED, (uint64_t)stream_id,
                    (uint64_t)error_code);
    return 0;
}

// The body source nghttp2 pulls from when sending a message with a payload.
static ssize_t beans_h2_read_body(nghttp2_session* session, int32_t stream_id,
                                  uint8_t* buf, size_t length,
                                  uint32_t* data_flags, nghttp2_data_source* source,
                                  void* user) {
    (void)session; (void)source;
    beans_h2_session* s = (beans_h2_session*)user;
    if (stream_id != s->pending_stream) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return 0;
    }
    size_t left = s->pending_body.len - s->pending_offset;
    size_t n = left < length ? left : length;
    if (n) memcpy(buf, s->pending_body.data + s->pending_offset, n);
    s->pending_offset += n;
    if (s->pending_offset >= s->pending_body.len) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    }
    return (ssize_t)n;
}

// ---- entry points -----------------------------------------------------------

// req: [0] is_server.
BEANS_NET_API long long beans_h2_new(const uint64_t* req) {
    if (!req) return 0;
    beans_h2_session* s = (beans_h2_session*)calloc(1, sizeof(beans_h2_session));
    if (!s) return 0;
    s->is_server = (int)beans_net_word(req, 0);
    s->pending_stream = -1;
    nghttp2_session_callbacks* callbacks = NULL;
    if (nghttp2_session_callbacks_new(&callbacks) != 0) { free(s); return 0; }
    nghttp2_session_callbacks_set_on_header_callback(callbacks, beans_h2_on_header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks,
                                                         beans_h2_on_frame_recv);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
        callbacks, beans_h2_on_data_chunk);
    nghttp2_session_callbacks_set_on_stream_close_callback(
        callbacks, beans_h2_on_stream_close);
    int rc = s->is_server
        ? nghttp2_session_server_new(&s->session, callbacks, s)
        : nghttp2_session_client_new(&s->session, callbacks, s);
    nghttp2_session_callbacks_del(callbacks);
    if (rc != 0) { free(s); return 0; }
    // The connection preface: both peers must send SETTINGS first.
    nghttp2_settings_entry settings[] = {
        {NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, 100},
        {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 65535},
    };
    if (nghttp2_submit_settings(s->session, NGHTTP2_FLAG_NONE, settings, 2) != 0) {
        nghttp2_session_del(s->session);
        free(s);
        return 0;
    }
    s->magic = BEANS_H2_MAGIC;
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_h2_free(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->session) nghttp2_session_del(s->session);
    free(s->events.data);
    free(s->pending_body.data);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

// Feeds received bytes into the session. Returns how many were consumed, or
// a negative status.
BEANS_NET_API long long beans_h2_feed(long long handle, const uint8_t* data,
                                      const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !req) return -(long long)BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return 0;
    if (!data) return -(long long)BEANS_NET_ERR_INVALID;
    ssize_t read = nghttp2_session_mem_recv(s->session, data, (size_t)len);
    if (read < 0) return -(long long)BEANS_H2_PROTOCOL;
    if (s->failed) return -(long long)BEANS_NET_ERR_MEMORY;
    return (long long)read;
}

// Drains frames the session wants to send into `out`; returns the byte count.
BEANS_NET_API long long beans_h2_pull_outgoing(long long handle, uint8_t* out,
                                               const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    size_t written = 0;
    while (written < cap) {
        const uint8_t* chunk = NULL;
        ssize_t n = nghttp2_session_mem_send(s->session, &chunk);
        if (n < 0) return -1;
        if (n == 0) break;
        size_t room = cap - written;
        size_t take = (size_t)n < room ? (size_t)n : room;
        memcpy(out + written, chunk, take);
        written += take;
        if (take < (size_t)n) {
            // The caller's buffer filled mid-frame. nghttp2 has already
            // handed the whole frame over, so a partial copy would lose the
            // tail: refuse instead of silently truncating.
            return -1;
        }
    }
    return (long long)written;
}

BEANS_NET_API long long beans_h2_want_write(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return 0;
    return nghttp2_session_want_write(s->session) ? 1 : 0;
}

BEANS_NET_API long long beans_h2_want_read(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return 0;
    return nghttp2_session_want_read(s->session) ? 1 : 0;
}

BEANS_NET_API long long beans_h2_events_size(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return -1;
    return (long long)s->events.len;
}

BEANS_NET_API long long beans_h2_take_events(long long handle, uint8_t* out,
                                             const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap < s->events.len) return -1;
    if (s->events.len && out) memcpy(out, s->events.data, s->events.len);
    long long taken = (long long)s->events.len;
    s->events.len = 0;
    return taken;
}

// Submits one message's headers, and optionally a body.
//
// Everything travels in ONE buffer, because a pointer smuggled through an
// integer word is a synthetic address in the interpreter and only a real
// RawPtr argument is materialized for C. The layout is:
//
//   [u64 name_len][u64 value_len] * count   little-endian length pairs
//   [names and values, concatenated]
//   [body]
//
// req describes it: [0] header count, [1] the length-pair region's size,
// [2] the name/value region's size, [3] body length, [4] stream id (server
// side), [5] reserved. Lengths are read byte-wise so the layout means the
// same thing on a big-endian target as on a little-endian one.
static uint64_t beans_h2_read_u64(const uint8_t* at) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value |= (uint64_t)at[i] << (i * 8);
    return value;
}

BEANS_NET_API long long beans_h2_submit(long long handle,
                                        const uint8_t* blob,
                                        const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !req || !blob) return -(long long)BEANS_NET_ERR_INVALID;
    uint64_t count = beans_net_word(req, 0);
    uint64_t lengths_bytes = beans_net_word(req, 1);
    uint64_t names_bytes = beans_net_word(req, 2);
    uint64_t body_len = beans_net_word(req, 3);
    int32_t stream_id = (int32_t)(long long)beans_net_word(req, 4);
    if (count == 0 || count > 256) return -(long long)BEANS_NET_ERR_INVALID;
    // The length region must describe exactly `count` pairs, and the pairs
    // must add up to the name region: a mismatch would have nghttp2 read
    // past the buffer.
    if (lengths_bytes != count * 16) return -(long long)BEANS_NET_ERR_INVALID;
    const uint8_t* lengths = blob;
    const uint8_t* names = blob + lengths_bytes;
    const uint8_t* body = blob + lengths_bytes + names_bytes;
    uint64_t total = 0;
    for (uint64_t i = 0; i < count * 2; i++) {
        total += beans_h2_read_u64(lengths + i * 8);
    }
    if (total != names_bytes) return -(long long)BEANS_NET_ERR_INVALID;

    nghttp2_nv* nv = (nghttp2_nv*)calloc((size_t)count, sizeof(nghttp2_nv));
    if (!nv) return -(long long)BEANS_NET_ERR_MEMORY;
    size_t offset = 0;
    for (uint64_t i = 0; i < count; i++) {
        size_t name_len = (size_t)beans_h2_read_u64(lengths + i * 16);
        size_t value_len = (size_t)beans_h2_read_u64(lengths + i * 16 + 8);
        nv[i].name = (uint8_t*)(uintptr_t)(names + offset);
        nv[i].namelen = name_len;
        offset += name_len;
        nv[i].value = (uint8_t*)(uintptr_t)(names + offset);
        nv[i].valuelen = value_len;
        offset += value_len;
        nv[i].flags = NGHTTP2_NV_FLAG_NONE;
    }

    nghttp2_data_provider provider;
    nghttp2_data_provider* provider_ptr = NULL;
    if (body_len > 0) {
        s->pending_body.len = 0;
        if (!beans_h2_buf_push(&s->pending_body, body, (size_t)body_len)) {
            free(nv);
            return -(long long)BEANS_NET_ERR_MEMORY;
        }
        s->pending_offset = 0;
        provider.source.ptr = NULL;
        provider.read_callback = beans_h2_read_body;
        provider_ptr = &provider;
    }

    long long result;
    if (s->is_server) {
        s->pending_stream = stream_id;
        int rc = nghttp2_submit_response(s->session, stream_id, nv,
                                         (size_t)count, provider_ptr);
        result = rc == 0 ? (long long)stream_id : -(long long)BEANS_H2_PROTOCOL;
    } else {
        int32_t opened = nghttp2_submit_request(s->session, NULL, nv,
                                                (size_t)count, provider_ptr, NULL);
        if (opened < 0) {
            result = -(long long)BEANS_H2_PROTOCOL;
        } else {
            s->pending_stream = opened;
            result = (long long)opened;
        }
    }
    free(nv);
    return result;
}

// Ends the session politely: GOAWAY with NO_ERROR.
BEANS_NET_API long long beans_h2_goaway(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (nghttp2_session_terminate_session(s->session, NGHTTP2_NO_ERROR) != 0)
        return BEANS_H2_PROTOCOL;
    return BEANS_NET_OK;
}

// Flow-control accounting, for the fuzzer's balance invariant: the
// connection-level send and receive windows as the session sees them.
BEANS_NET_API long long beans_h2_local_window(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return -1;
    return (long long)nghttp2_session_get_local_window_size(s->session);
}

BEANS_NET_API long long beans_h2_remote_window(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return -1;
    return (long long)nghttp2_session_get_remote_window_size(s->session);
}

BEANS_NET_API long long beans_h2_available(void) { return 1; }
