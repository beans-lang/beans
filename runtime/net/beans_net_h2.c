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
    BEANS_H2_BUSY = 132,      // one DATA chunk is still flow-control blocked
};

typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
} beans_h2_buf;

static int beans_h2_buf_reserve(beans_h2_buf* b, size_t more) {
    if (more > SIZE_MAX - b->len) return 0;
    size_t needed = b->len + more;
    if (needed <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < needed) {
        if (cap > SIZE_MAX / 2) { cap = needed; break; }
        cap *= 2;
    }
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
    int32_t stream;   // -1 when the slot is free
    size_t count;
    size_t bytes;
} beans_h2_header_state;

// nghttp2 follows the newer RFC 9113 rules. h2spec 2.6.0 still checks a
// handful of RFC 7540 rules which nghttp2 now deliberately ignores (the
// same cases fail against nghttpd). Keep the small amount of wire state
// needed to answer those frames here. This is also useful defence in depth:
// malformed control frames get an explicit protocol response instead of a
// silent timeout.
typedef struct {
    int32_t stream;
    int64_t remote_window;
    unsigned active : 1;
    unsigned peer_ended : 1;
    unsigned reset_received : 1;
} beans_h2_wire_stream;

typedef struct {
    nghttp2_session* session;
    beans_h2_buf events;
    // Bodies the Beans side handed us, one per in-flight stream; nghttp2
    // pulls from them through the read callback below.
    // Stable heap slots: nghttp2 keeps a slot pointer in data_source while
    // flow control defers a body. Growing this pointer table cannot move the
    // slot out from under that callback.
    beans_h2_pending** pending;
    size_t pending_count;
    // One body staged by the Beans call immediately before submit. It moves
    // into a stable pending slot without another whole-body copy.
    beans_h2_buf staged_body;
    beans_h2_header_state* header_states;
    size_t header_state_count;
    beans_h2_wire_stream* wire_streams;
    size_t wire_stream_count;
    int32_t last_peer_stream;
    uint8_t wire_header[9];
    size_t wire_header_len;
    uint8_t wire_prefix[5];
    size_t wire_prefix_len;
    uint32_t wire_payload_left;
    uint32_t wire_payload_len;
    uint8_t wire_type;
    uint8_t wire_flags;
    int32_t wire_stream;
    size_t preface_left;
    int manual_goaway;
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
        if (s->pending[i]->stream == stream) return s->pending[i];
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
        if (s->pending_count == SIZE_MAX / sizeof(*s->pending)) return NULL;
        size_t grown_count = s->pending_count + 1;
        beans_h2_pending** grown = (beans_h2_pending**)realloc(
            s->pending, grown_count * sizeof(*s->pending));
        if (!grown) return NULL;
        s->pending = grown;
        slot = (beans_h2_pending*)calloc(1, sizeof(*slot));
        if (!slot) return NULL;
        s->pending[s->pending_count] = slot;
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

static beans_h2_header_state* beans_h2_header_find(beans_h2_session* s,
                                                   int32_t stream) {
    for (size_t i = 0; i < s->header_state_count; i++) {
        if (s->header_states[i].stream == stream) return &s->header_states[i];
    }
    return NULL;
}

static beans_h2_header_state* beans_h2_header_claim(beans_h2_session* s,
                                                    int32_t stream) {
    beans_h2_header_state* slot = beans_h2_header_find(s, stream);
    if (slot) return slot;
    slot = beans_h2_header_find(s, -1);
    if (!slot) {
        if (s->header_state_count == SIZE_MAX / sizeof(*slot)) return NULL;
        size_t count = s->header_state_count + 1;
        beans_h2_header_state* grown = (beans_h2_header_state*)realloc(
            s->header_states, count * sizeof(*slot));
        if (!grown) return NULL;
        s->header_states = grown;
        slot = &s->header_states[s->header_state_count];
        memset(slot, 0, sizeof(*slot));
        s->header_state_count = count;
    }
    slot->stream = stream;
    slot->count = 0;
    slot->bytes = 0;
    return slot;
}

static void beans_h2_header_release(beans_h2_session* s, int32_t stream) {
    beans_h2_header_state* slot = beans_h2_header_find(s, stream);
    if (!slot) return;
    slot->stream = -1;
    slot->count = 0;
    slot->bytes = 0;
}

static beans_h2_wire_stream* beans_h2_wire_find(beans_h2_session* s,
                                                 int32_t stream) {
    for (size_t i = 0; i < s->wire_stream_count; i++) {
        if (s->wire_streams[i].stream == stream) return &s->wire_streams[i];
    }
    return NULL;
}

static beans_h2_wire_stream* beans_h2_wire_claim(beans_h2_session* s,
                                                  int32_t stream) {
    beans_h2_wire_stream* found = beans_h2_wire_find(s, stream);
    if (found) return found;
    // The peer can use roughly a billion stream ids over one connection. Do
    // not retain one record for each closed stream. The negotiated live-stream
    // limit is 100, so this leaves ample history for old-frame diagnostics.
    if (s->wire_stream_count >= 4096) {
        size_t oldest = SIZE_MAX;
        for (size_t i = 0; i < s->wire_stream_count; i++) {
            if (!s->wire_streams[i].active &&
                (oldest == SIZE_MAX ||
                 s->wire_streams[i].stream < s->wire_streams[oldest].stream))
                oldest = i;
        }
        if (oldest == SIZE_MAX) return NULL;
        found = &s->wire_streams[oldest];
        memset(found, 0, sizeof(*found));
        found->stream = stream;
        found->remote_window = 65535;
        found->active = 1;
        return found;
    }
    if (s->wire_stream_count == SIZE_MAX / sizeof(*s->wire_streams))
        return NULL;
    size_t count = s->wire_stream_count + 1;
    beans_h2_wire_stream* grown = (beans_h2_wire_stream*)realloc(
        s->wire_streams, count * sizeof(*grown));
    if (!grown) return NULL;
    s->wire_streams = grown;
    found = &grown[s->wire_stream_count];
    memset(found, 0, sizeof(*found));
    found->stream = stream;
    found->remote_window = 65535;
    found->active = 1;
    s->wire_stream_count = count;
    return found;
}

static void beans_h2_put_u32be(uint8_t* at, uint32_t value) {
    at[0] = (uint8_t)(value >> 24);
    at[1] = (uint8_t)(value >> 16);
    at[2] = (uint8_t)(value >> 8);
    at[3] = (uint8_t)value;
}

// Queues a bare RST_STREAM or GOAWAY in front of frames nghttp2 has not yet
// serialized. `outgoing` normally holds the tail of a frame that crossed a
// caller buffer; appending here preserves that already-committed order.
static int beans_h2_wire_error(beans_h2_session* s, int connection,
                               int32_t stream, uint32_t code) {
    if (connection && s->manual_goaway) return 1;
    if (s->outgoing_head == s->outgoing.len) {
        s->outgoing_head = 0;
        s->outgoing.len = 0;
    }
    uint8_t frame[17] = {0};
    if (connection) {
        frame[2] = 8;
        frame[3] = NGHTTP2_GOAWAY;
        beans_h2_put_u32be(frame + 9, (uint32_t)s->last_peer_stream);
        beans_h2_put_u32be(frame + 13, code);
        s->manual_goaway = 1;
        return beans_h2_buf_push(&s->outgoing, frame, sizeof(frame));
    }
    frame[2] = 4;
    frame[3] = NGHTTP2_RST_STREAM;
    beans_h2_put_u32be(frame + 5, (uint32_t)stream & 0x7fffffffU);
    beans_h2_put_u32be(frame + 9, code);
    return beans_h2_buf_push(&s->outgoing, frame, 13);
}

static uint32_t beans_h2_get_u32be(const uint8_t* at) {
    return ((uint32_t)at[0] << 24) | ((uint32_t)at[1] << 16) |
           ((uint32_t)at[2] << 8) | (uint32_t)at[3];
}

static void beans_h2_wire_frame(beans_h2_session* s) {
    int32_t id = s->wire_stream;
    beans_h2_wire_stream* state = id == 0 ? NULL : beans_h2_wire_find(s, id);
    if (s->wire_type == NGHTTP2_HEADERS) {
        if (state) {
            if (state->reset_received) {
                if (!beans_h2_wire_error(s, 0, id, NGHTTP2_STREAM_CLOSED))
                    s->failed = 1;
            } else if (state->peer_ended) {
                if (!beans_h2_wire_error(s, 1, id, NGHTTP2_STREAM_CLOSED))
                    s->failed = 1;
            }
        } else if (id != 0) {
            // A peer opens streams in increasing order. Reusing a lower id
            // is a connection error; a known closed stream was found above.
            if (s->is_server && id < s->last_peer_stream) {
                if (!beans_h2_wire_error(s, 1, id, NGHTTP2_PROTOCOL_ERROR))
                    s->failed = 1;
            } else {
                state = beans_h2_wire_claim(s, id);
                if (!state) { s->failed = 1; return; }
                if (id > s->last_peer_stream) s->last_peer_stream = id;
            }
        }
        if (state && (s->wire_flags & NGHTTP2_FLAG_END_STREAM))
            state->peer_ended = 1;
    } else if (s->wire_type == NGHTTP2_DATA) {
        if (state && (state->reset_received || state->peer_ended)) {
            if (!beans_h2_wire_error(s, 0, id, NGHTTP2_STREAM_CLOSED))
                s->failed = 1;
        }
        if (state && (s->wire_flags & NGHTTP2_FLAG_END_STREAM))
            state->peer_ended = 1;
    } else if (s->wire_type == NGHTTP2_RST_STREAM) {
        if (state) state->reset_received = 1;
    } else if (s->wire_type == NGHTTP2_PRIORITY) {
        if (id == 0) {
            if (!beans_h2_wire_error(s, 1, 0, NGHTTP2_PROTOCOL_ERROR))
                s->failed = 1;
        } else if (s->wire_payload_len == 5 && s->wire_prefix_len >= 4 &&
                   (int32_t)(beans_h2_get_u32be(s->wire_prefix) &
                             0x7fffffffU) == id) {
            if (!beans_h2_wire_error(s, 0, id, NGHTTP2_PROTOCOL_ERROR))
                s->failed = 1;
        }
    } else if (s->wire_type == NGHTTP2_WINDOW_UPDATE && id != 0 &&
               s->wire_payload_len == 4 && s->wire_prefix_len == 4) {
        uint32_t add = beans_h2_get_u32be(s->wire_prefix) & 0x7fffffffU;
        if (state && add != 0) {
            if (state->remote_window > INT32_MAX - (int64_t)add) {
                if (!beans_h2_wire_error(s, 0, id,
                                         NGHTTP2_FLOW_CONTROL_ERROR))
                    s->failed = 1;
                state->reset_received = 1;
            } else {
                state->remote_window += add;
            }
        }
    }
}

// Observes complete HTTP/2 frames without copying their payload. Feed calls
// may split either the 9-byte header or the payload at any byte.
static void beans_h2_wire_scan(beans_h2_session* s, const uint8_t* data,
                               size_t len) {
    size_t at = 0;
    if (s->preface_left) {
        size_t take = s->preface_left < len ? s->preface_left : len;
        s->preface_left -= take;
        at += take;
    }
    while (at < len) {
        if (s->wire_header_len < sizeof(s->wire_header)) {
            size_t need = sizeof(s->wire_header) - s->wire_header_len;
            size_t take = need < len - at ? need : len - at;
            memcpy(s->wire_header + s->wire_header_len, data + at, take);
            s->wire_header_len += take;
            at += take;
            if (s->wire_header_len < sizeof(s->wire_header)) return;
            s->wire_payload_len = ((uint32_t)s->wire_header[0] << 16) |
                                  ((uint32_t)s->wire_header[1] << 8) |
                                  (uint32_t)s->wire_header[2];
            s->wire_payload_left = s->wire_payload_len;
            s->wire_type = s->wire_header[3];
            s->wire_flags = s->wire_header[4];
            s->wire_stream = (int32_t)(beans_h2_get_u32be(
                s->wire_header + 5) & 0x7fffffffU);
            s->wire_prefix_len = 0;
            if (s->wire_payload_left == 0) {
                beans_h2_wire_frame(s);
                s->wire_header_len = 0;
                continue;
            }
        }
        size_t take = s->wire_payload_left < len - at
            ? s->wire_payload_left : len - at;
        size_t keep = sizeof(s->wire_prefix) - s->wire_prefix_len;
        if (keep > take) keep = take;
        if (keep) {
            memcpy(s->wire_prefix + s->wire_prefix_len, data + at, keep);
            s->wire_prefix_len += keep;
        }
        at += take;
        s->wire_payload_left -= (uint32_t)take;
        if (s->wire_payload_left == 0) {
            beans_h2_wire_frame(s);
            s->wire_header_len = 0;
        }
    }
}

static int32_t beans_h2_header_stream(const nghttp2_frame* frame) {
    return frame->hd.type == NGHTTP2_PUSH_PROMISE
        ? frame->push_promise.promised_stream_id
        : frame->hd.stream_id;
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
    (void)flags;
    beans_h2_session* s = (beans_h2_session*)user;
    int32_t stream_id = beans_h2_header_stream(frame);
    beans_h2_header_state* limits = beans_h2_header_claim(s, stream_id);
    if (!limits) {
        s->failed = 1;
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    if (namelen > SIZE_MAX - valuelen ||
        namelen + valuelen > SIZE_MAX - limits->bytes ||
        limits->count >= 128 || limits->bytes + namelen + valuelen > 65536) {
        (void)nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream_id,
                                        NGHTTP2_ENHANCE_YOUR_CALM);
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }
    limits->count++;
    limits->bytes += namelen + valuelen;
    uint8_t head[1 + 8 + 8 + 8];
    head[0] = BEANS_H2_EV_HEADER;
    beans_h2_put_u64(head + 1, (uint64_t)stream_id);
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
        flags |= (uint64_t)frame->headers.cat << 1;
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
    beans_h2_header_release(s, stream_id);
    beans_h2_wire_stream* wire = beans_h2_wire_find(s, stream_id);
    if (wire) wire->active = 0;
    beans_h2_event3(s, BEANS_H2_EV_STREAM_CLOSED, (uint64_t)stream_id,
                    (uint64_t)error_code);
    return 0;
}

// The body source nghttp2 pulls from when sending a message with a payload.
static ssize_t beans_h2_read_body(nghttp2_session* session, int32_t stream_id,
                                  uint8_t* buf, size_t length,
                                  uint32_t* data_flags, nghttp2_data_source* source,
                                  void* user) {
    (void)session;
    beans_h2_session* s = (beans_h2_session*)user;
    beans_h2_pending* slot = (beans_h2_pending*)source->ptr;
    if (!slot || slot->stream != stream_id) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return 0;
    }
    // Both sides are size_t, so the comparison guards a wrap: an offset past
    // len would make `len - offset` underflow to near SIZE_MAX and copy
    // whatever follows the buffer straight onto the wire.
    if (slot->offset >= slot->body.len) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        beans_h2_pending_release(s, stream_id);
        return 0;
    }
    size_t left = slot->body.len - slot->offset;
    size_t n = left < length ? left : length;
    if (n) memcpy(buf, slot->body.data + slot->offset, n);
    slot->offset += n;
    if (slot->offset >= slot->body.len) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        beans_h2_pending_release(s, stream_id);
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
    s->preface_left = s->is_server ? 24 : 0;
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
    free(s->staged_body.data);
    for (size_t i = 0; i < s->pending_count; i++) {
        free(s->pending[i]->body.data);
        free(s->pending[i]);
    }
    free(s->pending);
    free(s->header_states);
    free(s->wire_streams);
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
    if (len > SIZE_MAX) return -(long long)BEANS_NET_ERR_RANGE;
    beans_h2_wire_scan(s, data, (size_t)len);
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
    if (cap > SIZE_MAX) cap = SIZE_MAX;
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
// req describes it: [0] header count, [1] the length-pair region's size,
// [2] the name/value region's size, [3] body length, [4] stream id (server
// side), [5] total header blob length, [6] keep the stream open for later
// DATA. Lengths are read byte-wise so the layout means the same thing on a
// big-endian target as on a little-endian one.
static uint64_t beans_h2_read_u64(const uint8_t* at) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value |= (uint64_t)at[i] << (i * 8);
    return value;
}

// Copies one outgoing body directly into native storage. submit() then
// transfers this buffer to nghttp2's stable per-stream slot, so the Beans
// side does not build a second header+body blob and C does not copy it again.
BEANS_NET_API long long beans_h2_stage_body(long long handle,
                                            const uint8_t* body,
                                            const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len > SIZE_MAX || (len > 0 && !body)) return BEANS_NET_ERR_RANGE;
    s->staged_body.len = 0;
    if (!beans_h2_buf_push(&s->staged_body, body, (size_t)len))
        return BEANS_NET_ERR_MEMORY;
    return BEANS_NET_OK;
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
    uint64_t blob_len = beans_net_word(req, 5);
    uint64_t keep_open = beans_net_word(req, 6);
    if (count == 0 || count > 256) return -(long long)BEANS_NET_ERR_INVALID;
    if (keep_open > 1 || (keep_open && body_len != 0))
        return -(long long)BEANS_NET_ERR_INVALID;
    // The length region must describe exactly `count` pairs, and the pairs
    // must add up to the name region: a mismatch would have nghttp2 read
    // past the buffer.
    if (count > UINT64_MAX / 16 || lengths_bytes != count * 16 ||
        lengths_bytes > UINT64_MAX - names_bytes ||
        blob_len != lengths_bytes + names_bytes)
        return -(long long)BEANS_NET_ERR_INVALID;
    if (lengths_bytes > SIZE_MAX || names_bytes > SIZE_MAX ||
        body_len > SIZE_MAX || s->staged_body.len != (size_t)body_len)
        return -(long long)BEANS_NET_ERR_RANGE;
    const uint8_t* lengths = blob;
    const uint8_t* names = blob + lengths_bytes;
    uint64_t total = 0;
    for (uint64_t i = 0; i < count * 2; i++) {
        uint64_t part = beans_h2_read_u64(lengths + i * 8);
        if (part > UINT64_MAX - total)
            return -(long long)BEANS_NET_ERR_RANGE;
        total += part;
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
        beans_h2_buf reusable = slot->body;
        slot->body = s->staged_body;
        s->staged_body = reusable;
        s->staged_body.len = 0;
        slot->offset = 0;
        provider.source.ptr = slot;
        provider.read_callback = beans_h2_read_body;
        provider_ptr = &provider;
    }

    long long result;
    if (keep_open) {
        int32_t opened = nghttp2_submit_headers(
            s->session, NGHTTP2_FLAG_NONE,
            s->is_server ? stream_id : -1, NULL, nv, (size_t)count, NULL);
        if (opened < 0) {
            result = -(long long)BEANS_H2_PROTOCOL;
        } else {
            result = (long long)(s->is_server ? stream_id : opened);
        }
    } else if (s->is_server) {
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

// Submits one DATA chunk after a keep-open header block. The staged body is
// moved into a stable slot and nghttp2 pulls only what the peer's flow-control
// window permits. req: [0] stream id, [1] end_stream.
BEANS_NET_API long long beans_h2_submit_data(long long handle,
                                             const uint64_t* req) {
    beans_h2_session* s = beans_h2_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    int64_t raw_stream = (int64_t)beans_net_word(req, 0);
    uint64_t end_stream = beans_net_word(req, 1);
    if (raw_stream <= 0 || raw_stream > INT32_MAX || end_stream > 1)
        return BEANS_NET_ERR_INVALID;
    int32_t stream_id = (int32_t)raw_stream;
    if (beans_h2_pending_find(s, stream_id)) return BEANS_H2_BUSY;

    beans_h2_pending* slot = beans_h2_pending_claim(s, stream_id);
    if (!slot) return BEANS_NET_ERR_MEMORY;
    beans_h2_buf reusable = slot->body;
    slot->body = s->staged_body;
    s->staged_body = reusable;
    s->staged_body.len = 0;
    slot->offset = 0;

    nghttp2_data_provider provider;
    provider.source.ptr = slot;
    provider.read_callback = beans_h2_read_body;
    int rc = nghttp2_submit_data(
        s->session,
        end_stream ? NGHTTP2_FLAG_END_STREAM : NGHTTP2_FLAG_NONE,
        stream_id, &provider);
    if (rc != 0) {
        beans_h2_pending_release(s, stream_id);
        return rc == NGHTTP2_ERR_DATA_EXIST ? BEANS_H2_BUSY : BEANS_H2_PROTOCOL;
    }
    return BEANS_NET_OK;
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
