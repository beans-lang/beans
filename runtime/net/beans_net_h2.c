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

// One outgoing body, owned per stream. HTTP/2 is multiplexed, so a single
// shared slot is wrong: a body deferred by flow control stays pending while
// the caller opens other streams, and whichever submit ran last would steal
// the slot and end the deferred stream early with END_STREAM.
typedef struct {
    beans_h2_buf body;
    size_t offset;
    int32_t stream;   // -1 when the slot is free
} beans_h2_pending;

typedef struct {
    nghttp2_session* session;
    beans_h2_buf events;
    // Bodies the Beans side handed us, one per in-flight stream; nghttp2
    // pulls from them through the read callback below.
    beans_h2_pending* pending;
    size_t pending_count;
    // Frame bytes nghttp2 handed over that did not fit the caller's buffer.
    // mem_send commits a frame as it returns it, so the tail has to be kept
    // here -- it cannot be re-fetched.
    beans_h2_buf outgoing;
    size_t outgoing_head;
    int is_server;
    int failed;
    uint64_t magic;
} beans_h2_session;

// Finds the slot holding `stream`'s body, or NULL.
static beans_h2_pending* beans_h2_pending_find(beans_h2_session* s,
                                               int32_t stream) {
    for (size_t i = 0; i < s->pending_count; i++) {
        if (s->pending[i].stream == stream) return &s->pending[i];
    }
    return NULL;
}

// Reuses a free slot or grows the table. Returns NULL only on OOM.
static beans_h2_pending* beans_h2_pending_claim(beans_h2_session* s,
                                                int32_t stream) {
    beans_h2_pending* slot = beans_h2_pending_find(s, stream);
    if (slot) { slot->body.len = 0; slot->offset = 0; return slot; }
    slot = beans_h2_pending_find(s, -1);
    if (!slot) {
        size_t grown_count = s->pending_count + 1;
        beans_h2_pending* grown = (beans_h2_pending*)realloc(
            s->pending, grown_count * sizeof(beans_h2_pending));
        if (!grown) return NULL;
        s->pending = grown;
        slot = &s->pending[s->pending_count];
        memset(slot, 0, sizeof *slot);
        s->pending_count = grown_count;
    }
    slot->stream = stream;
    slot->body.len = 0;
    slot->offset = 0;
    return slot;
}

// Frees a slot for reuse. The buffer stays allocated; the table is small and
// bounded by concurrent streams with bodies.
static void beans_h2_pending_release(beans_h2_session* s, int32_t stream) {
    beans_h2_pending* slot = beans_h2_pending_find(s, stream);
    if (!slot) return;
    slot->stream = -1;
    slot->body.len = 0;
    slot->offset = 0;
}

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
    beans_h2_pending_release(s, stream_id);
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
    beans_h2_pending* slot = beans_h2_pending_find(s, stream_id);
    if (!slot) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return 0;
    }
    // Both sides are size_t, so the comparison guards a wrap: an offset past
    // len would make `len - offset` underflow to near SIZE_MAX and copy
    // whatever follows the buffer straight onto the wire.
    if (slot->offset >= slot->body.len) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return 0;
    }
    size_t left = slot->body.len - slot->offset;
    size_t n = left < length ? left : length;
    if (n) memcpy(buf, slot->body.data + slot->offset, n);
    slot->offset += n;
    if (slot->offset >= slot->body.len) {
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
    free(s->outgoing.data);
    for (size_t i = 0; i < s->pending_count; i++) free(s->pending[i].body.data);
    free(s->pending);
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
    // Anything left over from the previous call goes first, so frames leave
    // in order.
    size_t held = s->outgoing.len - s->outgoing_head;
    if (held > 0) {
        size_t take = held < cap ? held : (size_t)cap;
        memcpy(out, s->outgoing.data + s->outgoing_head, take);
        s->outgoing_head += take;
        written += take;
        if (s->outgoing_head == s->outgoing.len) {
            s->outgoing.len = 0;
            s->outgoing_head = 0;
        } else {
            // Still more held than the caller asked for; nothing new yet.
            return (long long)written;
        }
    }
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
            // The caller's buffer filled mid-frame. mem_send has already
            // committed this frame and cannot replay it, so the tail is kept
            // here and served at the head of the next call. Refusing instead
            // would destroy the frame and kill the connection for any body
            // that outgrows the caller's buffer.
            if (!beans_h2_buf_push(&s->outgoing, chunk + take,
                                   (size_t)n - take)) {
                s->failed = 1;
                return -1;
            }
            break;
        }
    }
    return (long long)written;
}

BEANS_NET_API long long beans_h2_want_write(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return 0;
    // Bytes held back from a straddling frame still need to go out, even
    // when nghttp2 itself has nothing more queued.
    if (s->outgoing.len > s->outgoing_head) return 1;
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
    // `out` is required, matching the ws bridge: accepting NULL here would
    // skip the copy, still clear the queue, and destroy the events silently.
    if (!s || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap < s->events.len) return -1;
    if (s->events.len) memcpy(out, s->events.data, s->events.len);
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
    // The server knows its stream up front; the client only learns it from
    // submit_request, so its body is staged under a placeholder and rebound
    // once nghttp2 assigns the id.
    beans_h2_pending* slot = NULL;
    if (body_len > 0) {
        slot = beans_h2_pending_claim(s, s->is_server ? stream_id : 0);
        if (!slot) {
            free(nv);
            return -(long long)BEANS_NET_ERR_MEMORY;
        }
        if (!beans_h2_buf_push(&slot->body, body, (size_t)body_len)) {
            // Leave no half-filled slot behind: read_body would then serve a
            // stale offset against an empty buffer.
            slot->stream = -1;
            free(nv);
            return -(long long)BEANS_NET_ERR_MEMORY;
        }
        provider.source.ptr = NULL;
        provider.read_callback = beans_h2_read_body;
        provider_ptr = &provider;
    }

    long long result;
    if (s->is_server) {
        int rc = nghttp2_submit_response(s->session, stream_id, nv,
                                         (size_t)count, provider_ptr);
        if (rc != 0) {
            if (slot) slot->stream = -1;
            result = -(long long)BEANS_H2_PROTOCOL;
        } else {
            result = (long long)stream_id;
        }
    } else {
        int32_t opened = nghttp2_submit_request(s->session, NULL, nv,
                                                (size_t)count, provider_ptr, NULL);
        if (opened < 0) {
            if (slot) slot->stream = -1;
            result = -(long long)BEANS_H2_PROTOCOL;
        } else {
            if (slot) slot->stream = opened;
            result = (long long)opened;
        }
    }
    free(nv);
    return result;
}

// Cancels one stream without touching the rest of the connection --
// RST_STREAM with the given error code. Used when a message crosses a limit
// the peer should hear about.
BEANS_NET_API long long beans_h2_rst_stream(long long handle,
                                            const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    int32_t stream_id = (int32_t)(long long)beans_net_word(req, 0);
    uint32_t code = (uint32_t)beans_net_word(req, 1);
    beans_h2_pending_release(s, stream_id);
    if (nghttp2_submit_rst_stream(s->session, NGHTTP2_FLAG_NONE, stream_id,
                                  code) != 0)
        return BEANS_H2_PROTOCOL;
    return BEANS_NET_OK;
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
// Both window getters report a genuinely signed value -- the remote window
// goes negative when the peer shrinks SETTINGS_INITIAL_WINDOW_SIZE below what
// is already in flight -- so a bad handle cannot answer -1 without colliding
// with a real reading. The sentinel sits below any legal window instead.
enum { BEANS_H2_NO_WINDOW = -0x80000000LL - 1 };

BEANS_NET_API long long beans_h2_local_window(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return BEANS_H2_NO_WINDOW;
    return (long long)nghttp2_session_get_local_window_size(s->session);
}

BEANS_NET_API long long beans_h2_remote_window(long long handle) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s) return BEANS_H2_NO_WINDOW;
    return (long long)nghttp2_session_get_remote_window_size(s->session);
}

BEANS_NET_API long long beans_h2_available(void) { return 1; }
