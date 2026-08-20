// HTTP/1.1 parsing for std.http — llhttp under a trace-event ABI.
//
// llhttp's generated core calls one trampoline per parser event, passing the
// live cursor: `llhttp__on_url(state, p, endp)`. The public settings API in
// api.c throws the cursor away, so this bridge does not use it — api.c's
// trampolines are renamed out of the way at preprocessing time and this file
// provides its own, which record each event with its exact byte offset into
// a per-parser buffer the Beans side drains after each feed. No stored
// callbacks, no registry, no C-to-Beans calls at all: llhttp_execute runs,
// events accumulate, Beans reads them out.
//
// The offsets make the stream simultaneously the substrate for the public
// std.http parser AND a faithful reproduction of llhttp's own test-fixture
// trace, so the upstream markdown corpus replays against this bridge line
// for line. Span events merge when byte-adjacent and same-type — the visible
// behaviour of upstream's span printer — so a message split at any byte
// yields the identical stream.
//
// Event encoding, little-endian, per event:
//   [u8 type][u64 off]                      begins / completes / reset / pause
//   [u8 span][u64 off][u64 len][bytes]      spans
//   [u8 21][u64 off][u64 method][u64 status][u64 major][u64 minor]
//          [u64 flags][u64 content_length][u8 upgrade][u8 keep_alive]
//   [u8 22][u64 off][u64 chunk_length]      chunk header
//   [u8 27][u64 off][u64 code][u64 len][reason bytes]
//
// The lenient / pause / skip-body knobs exist for the corpus runner only;
// the public std.http surface never sets them and stays strict.

#include "beans_net_common.h"

#include "vendor/llhttp/llhttp.h"

// The generated parser core (vendor/llhttp/llhttp.c) compiles as its own
// translation unit beside this one — its internal declarations spell the
// cursor as `const unsigned char*` while api.c spells `const char*`, which
// only separate units tolerate, exactly as upstream builds them. api.c and
// http.c compile here, with api.c's cursor-dropping trampoline definitions
// renamed out of the way so the definitions below take their place; its
// public entry points (llhttp_init, llhttp_execute, llhttp_resume, ...) and
// http.c's real semantics (llhttp__before/after_headers_complete, ...) are
// kept exactly as shipped.
#define llhttp__on_message_begin beans_h1_shelved_on_message_begin
#define llhttp__on_protocol beans_h1_shelved_on_protocol
#define llhttp__on_protocol_complete beans_h1_shelved_on_protocol_complete
#define llhttp__on_url beans_h1_shelved_on_url
#define llhttp__on_url_complete beans_h1_shelved_on_url_complete
#define llhttp__on_status beans_h1_shelved_on_status
#define llhttp__on_status_complete beans_h1_shelved_on_status_complete
#define llhttp__on_method beans_h1_shelved_on_method
#define llhttp__on_method_complete beans_h1_shelved_on_method_complete
#define llhttp__on_version beans_h1_shelved_on_version
#define llhttp__on_version_complete beans_h1_shelved_on_version_complete
#define llhttp__on_header_field beans_h1_shelved_on_header_field
#define llhttp__on_header_field_complete beans_h1_shelved_on_header_field_complete
#define llhttp__on_header_value beans_h1_shelved_on_header_value
#define llhttp__on_header_value_complete beans_h1_shelved_on_header_value_complete
#define llhttp__on_headers_complete beans_h1_shelved_on_headers_complete
#define llhttp__on_message_complete beans_h1_shelved_on_message_complete
#define llhttp__on_body beans_h1_shelved_on_body
#define llhttp__on_chunk_header beans_h1_shelved_on_chunk_header
#define llhttp__on_chunk_extension_name beans_h1_shelved_on_chunk_extension_name
#define llhttp__on_chunk_extension_name_complete beans_h1_shelved_on_chunk_extension_name_complete
#define llhttp__on_chunk_extension_value beans_h1_shelved_on_chunk_extension_value
#define llhttp__on_chunk_extension_value_complete beans_h1_shelved_on_chunk_extension_value_complete
#define llhttp__on_chunk_complete beans_h1_shelved_on_chunk_complete
#define llhttp__on_reset beans_h1_shelved_on_reset
#include "vendor/llhttp/api.c"
#include "vendor/llhttp/http.c"
#undef llhttp__on_message_begin
#undef llhttp__on_protocol
#undef llhttp__on_protocol_complete
#undef llhttp__on_url
#undef llhttp__on_url_complete
#undef llhttp__on_status
#undef llhttp__on_status_complete
#undef llhttp__on_method
#undef llhttp__on_method_complete
#undef llhttp__on_version
#undef llhttp__on_version_complete
#undef llhttp__on_header_field
#undef llhttp__on_header_field_complete
#undef llhttp__on_header_value
#undef llhttp__on_header_value_complete
#undef llhttp__on_headers_complete
#undef llhttp__on_message_complete
#undef llhttp__on_body
#undef llhttp__on_chunk_header
#undef llhttp__on_chunk_extension_name
#undef llhttp__on_chunk_extension_name_complete
#undef llhttp__on_chunk_extension_value
#undef llhttp__on_chunk_extension_value_complete
#undef llhttp__on_chunk_complete
#undef llhttp__on_reset

enum {
    BEANS_H1_EV_MESSAGE_BEGIN = 1,
    BEANS_H1_EV_SPAN_METHOD = 2,
    BEANS_H1_EV_SPAN_URL = 3,
    BEANS_H1_EV_SPAN_PROTOCOL = 4,
    BEANS_H1_EV_SPAN_VERSION = 5,
    BEANS_H1_EV_SPAN_STATUS = 6,
    BEANS_H1_EV_SPAN_HEADER_FIELD = 7,
    BEANS_H1_EV_SPAN_HEADER_VALUE = 8,
    BEANS_H1_EV_SPAN_CHUNK_EXT_NAME = 9,
    BEANS_H1_EV_SPAN_CHUNK_EXT_VALUE = 10,
    BEANS_H1_EV_SPAN_BODY = 11,
    BEANS_H1_EV_METHOD_COMPLETE = 12,
    BEANS_H1_EV_URL_COMPLETE = 13,
    BEANS_H1_EV_PROTOCOL_COMPLETE = 14,
    BEANS_H1_EV_VERSION_COMPLETE = 15,
    BEANS_H1_EV_STATUS_COMPLETE = 16,
    BEANS_H1_EV_HEADER_FIELD_COMPLETE = 17,
    BEANS_H1_EV_HEADER_VALUE_COMPLETE = 18,
    BEANS_H1_EV_CHUNK_EXT_NAME_COMPLETE = 19,
    BEANS_H1_EV_CHUNK_EXT_VALUE_COMPLETE = 20,
    BEANS_H1_EV_HEADERS_COMPLETE = 21,
    BEANS_H1_EV_CHUNK_HEADER = 22,
    BEANS_H1_EV_CHUNK_COMPLETE = 23,
    BEANS_H1_EV_MESSAGE_COMPLETE = 24,
    BEANS_H1_EV_RESET = 25,
    BEANS_H1_EV_PAUSE = 26,
    BEANS_H1_EV_ERROR = 27,
    BEANS_H1_EV_SKIP_BODY = 28,
};

typedef struct {
    // llhttp writes through the llhttp_t* it is handed, which is this first
    // member — so a trampoline's state pointer IS the session.
    llhttp_t parser;
    uint8_t* events;
    size_t events_len;
    size_t events_cap;
    // `base` counts bytes consumed by earlier execute calls; `chunk` is the
    // buffer currently inside llhttp_execute, so callbacks can turn their
    // cursor into an absolute offset.
    uint64_t base;
    const char* chunk;
    size_t chunk_len;
    // Pending same-type byte-adjacent span merge.
    int span_type;
    uint64_t span_off;
    size_t span_event;
    size_t span_len;
    // Public typed parsers consume spans while the feed buffer is alive, so
    // their event records carry offsets only. Corpus mode keeps copying bytes
    // because its trace ABI is a self-contained byte stream.
    int span_refs;
    // Corpus-runner knobs.
    int pause_on;
    int skip_body;
    int out_of_memory;
    uint64_t magic;
} beans_h1_session;

#define BEANS_H1_MAGIC 0x62656e7368317631ULL

static beans_h1_session* beans_h1_of(long long handle) {
    beans_h1_session* s = (beans_h1_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_H1_MAGIC) return NULL;
    return s;
}

static int beans_h1_reserve(beans_h1_session* s, size_t more) {
    if (more > SIZE_MAX - s->events_len) {
        s->out_of_memory = 1;
        return 0;
    }
    size_t needed = s->events_len + more;
    if (needed <= s->events_cap) return 1;
    size_t cap = s->events_cap ? s->events_cap : 256;
    while (cap < needed) {
        if (cap > SIZE_MAX / 2) { cap = needed; break; }
        cap *= 2;
    }
    uint8_t* grown = (uint8_t*)realloc(s->events, cap);
    if (!grown) {
        s->out_of_memory = 1;
        return 0;
    }
    s->events = grown;
    s->events_cap = cap;
    return 1;
}

static void beans_h1_put_u64(uint8_t* at, uint64_t value) {
    for (int i = 0; i < 8; i++) at[i] = (uint8_t)(value >> (i * 8));
}

static uint64_t beans_h1_cursor(beans_h1_session* s, const char* p) {
    if (!p || !s->chunk) return s->base;
    return s->base + (uint64_t)(p - s->chunk);
}

static void beans_h1_flush_span(beans_h1_session* s) {
    if (!s->span_type) return;
    s->span_type = 0;
    s->span_len = 0;
}

static void beans_h1_plain(beans_h1_session* s, int type, uint64_t off) {
    beans_h1_flush_span(s);
    if (!beans_h1_reserve(s, 1 + 8)) return;
    uint8_t* at = s->events + s->events_len;
    at[0] = (uint8_t)type;
    beans_h1_put_u64(at + 1, off);
    s->events_len += 9;
}

static int beans_h1_span(beans_h1_session* s, int type,
                         const char* p, const char* endp) {
#ifdef BEANS_H1_DEBUG
    if (endp < p || p < s->chunk || endp > s->chunk + s->chunk_len) {
        fprintf(stderr,
                "SPAN OOB type=%d p=%p endp=%p chunk=%p+%zu delta=%ld\n",
                type, (const void*)p, (const void*)endp,
                (const void*)s->chunk, s->chunk_len, (long)(endp - p));
        abort();
    }
#endif
    uint64_t off = beans_h1_cursor(s, p);
    size_t len = (size_t)(endp - p);
    if (!(s->span_type == type &&
          s->span_len <= UINT64_MAX - s->span_off &&
          s->span_off + s->span_len == off)) {
        beans_h1_flush_span(s);
        size_t payload = s->span_refs ? 0 : len;
        if (payload > SIZE_MAX - 17 ||
            !beans_h1_reserve(s, 17 + payload))
            return HPE_INTERNAL;
        s->span_type = type;
        s->span_off = off;
        s->span_event = s->events_len;
        uint8_t* at = s->events + s->events_len;
        at[0] = (uint8_t)type;
        beans_h1_put_u64(at + 1, off);
        beans_h1_put_u64(at + 9, (uint64_t)len);
        if (!s->span_refs && len) memcpy(at + 17, p, len);
        s->events_len += 17 + payload;
        s->span_len = len;
    } else {
        if (len > SIZE_MAX - s->span_len) return HPE_INTERNAL;
        if (!s->span_refs) {
            if (!beans_h1_reserve(s, len)) return HPE_INTERNAL;
            if (len) memcpy(s->events + s->events_len, p, len);
            s->events_len += len;
        }
        s->span_len += len;
        beans_h1_put_u64(s->events + s->span_event + 9,
                         (uint64_t)s->span_len);
    }
    if (s->pause_on == type) return HPE_PAUSED;
    return 0;
}

// ---- the trampolines llhttp's generated core calls ------------------------

#define BEANS_H1_SPAN_CB(name, type)                                          \
    int name(llhttp_t* state, const char* p, const char* endp) {              \
        return beans_h1_span((beans_h1_session*)state, type, p, endp);        \
    }

#define BEANS_H1_PLAIN_CB(name, type)                                         \
    int name(llhttp_t* state, const char* p, const char* endp) {              \
        beans_h1_session* s = (beans_h1_session*)state;                       \
        (void)endp;                                                           \
        beans_h1_plain(s, type, beans_h1_cursor(s, p));                       \
        if (s->pause_on == type) return HPE_PAUSED;                           \
        return 0;                                                             \
    }

BEANS_H1_PLAIN_CB(llhttp__on_message_begin, BEANS_H1_EV_MESSAGE_BEGIN)
BEANS_H1_SPAN_CB(llhttp__on_method, BEANS_H1_EV_SPAN_METHOD)
BEANS_H1_PLAIN_CB(llhttp__on_method_complete, BEANS_H1_EV_METHOD_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_url, BEANS_H1_EV_SPAN_URL)
BEANS_H1_PLAIN_CB(llhttp__on_url_complete, BEANS_H1_EV_URL_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_protocol, BEANS_H1_EV_SPAN_PROTOCOL)
BEANS_H1_PLAIN_CB(llhttp__on_protocol_complete, BEANS_H1_EV_PROTOCOL_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_version, BEANS_H1_EV_SPAN_VERSION)
BEANS_H1_PLAIN_CB(llhttp__on_version_complete, BEANS_H1_EV_VERSION_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_status, BEANS_H1_EV_SPAN_STATUS)
BEANS_H1_PLAIN_CB(llhttp__on_status_complete, BEANS_H1_EV_STATUS_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_header_field, BEANS_H1_EV_SPAN_HEADER_FIELD)
BEANS_H1_PLAIN_CB(llhttp__on_header_field_complete, BEANS_H1_EV_HEADER_FIELD_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_header_value, BEANS_H1_EV_SPAN_HEADER_VALUE)
BEANS_H1_PLAIN_CB(llhttp__on_header_value_complete, BEANS_H1_EV_HEADER_VALUE_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_chunk_extension_name, BEANS_H1_EV_SPAN_CHUNK_EXT_NAME)
BEANS_H1_PLAIN_CB(llhttp__on_chunk_extension_name_complete,
                  BEANS_H1_EV_CHUNK_EXT_NAME_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_chunk_extension_value, BEANS_H1_EV_SPAN_CHUNK_EXT_VALUE)
BEANS_H1_PLAIN_CB(llhttp__on_chunk_extension_value_complete,
                  BEANS_H1_EV_CHUNK_EXT_VALUE_COMPLETE)
BEANS_H1_SPAN_CB(llhttp__on_body, BEANS_H1_EV_SPAN_BODY)
BEANS_H1_PLAIN_CB(llhttp__on_message_complete, BEANS_H1_EV_MESSAGE_COMPLETE)
BEANS_H1_PLAIN_CB(llhttp__on_chunk_complete, BEANS_H1_EV_CHUNK_COMPLETE)
BEANS_H1_PLAIN_CB(llhttp__on_reset, BEANS_H1_EV_RESET)

int llhttp__on_headers_complete(llhttp_t* state, const char* p, const char* endp) {
    beans_h1_session* s = (beans_h1_session*)state;
    (void)endp;
    beans_h1_flush_span(s);
    if (beans_h1_reserve(s, 1 + 8 + 6 * 8 + 2)) {
        uint8_t* at = s->events + s->events_len;
        at[0] = BEANS_H1_EV_HEADERS_COMPLETE;
        beans_h1_put_u64(at + 1, beans_h1_cursor(s, p));
        beans_h1_put_u64(at + 9, (uint64_t)state->method);
        beans_h1_put_u64(at + 17, (uint64_t)state->status_code);
        beans_h1_put_u64(at + 25, (uint64_t)state->http_major);
        beans_h1_put_u64(at + 33, (uint64_t)state->http_minor);
        beans_h1_put_u64(at + 41, (uint64_t)state->flags);
        beans_h1_put_u64(at + 49, state->content_length);
        at[57] = state->upgrade;
        at[58] = (uint8_t)(llhttp_should_keep_alive(state) ? 1 : 0);
        s->events_len += 1 + 8 + 6 * 8 + 2;
    }
    if (s->skip_body) {
        beans_h1_plain(s, BEANS_H1_EV_SKIP_BODY, beans_h1_cursor(s, p));
        return 1;
    }
    if (s->pause_on == BEANS_H1_EV_HEADERS_COMPLETE) return HPE_PAUSED;
    return 0;
}

int llhttp__on_chunk_header(llhttp_t* state, const char* p, const char* endp) {
    beans_h1_session* s = (beans_h1_session*)state;
    (void)endp;
    beans_h1_flush_span(s);
    if (beans_h1_reserve(s, 1 + 8 + 8)) {
        uint8_t* at = s->events + s->events_len;
        at[0] = BEANS_H1_EV_CHUNK_HEADER;
        beans_h1_put_u64(at + 1, beans_h1_cursor(s, p));
        beans_h1_put_u64(at + 9, state->content_length);
        s->events_len += 1 + 8 + 8;
    }
    if (s->pause_on == BEANS_H1_EV_CHUNK_HEADER) return HPE_PAUSED;
    return 0;
}

static void beans_h1_error_event(beans_h1_session* s, int code,
                                 const char* reason, uint64_t off) {
    beans_h1_flush_span(s);
    size_t rlen = reason ? strlen(reason) : 0;
    if (!beans_h1_reserve(s, 1 + 8 + 8 + 8 + rlen)) return;
    uint8_t* at = s->events + s->events_len;
    at[0] = BEANS_H1_EV_ERROR;
    beans_h1_put_u64(at + 1, off);
    beans_h1_put_u64(at + 9, (uint64_t)code);
    beans_h1_put_u64(at + 17, (uint64_t)rlen);
    if (rlen) memcpy(at + 25, reason, rlen);
    s->events_len += 1 + 8 + 8 + 8 + rlen;
}

// ---- entry points ----------------------------------------------------------

// kind: 0 = request parser, 1 = response parser, 2 = either. Adding 10 asks
// for offset-only span records used by the public typed parser.
BEANS_NET_API long long beans_h1_new(long long kind) {
    beans_h1_session* s = (beans_h1_session*)calloc(1, sizeof(beans_h1_session));
    if (!s) return 0;
    s->magic = BEANS_H1_MAGIC;
    s->span_refs = kind >= 10;
    if (s->span_refs) kind -= 10;
    llhttp_type_t type =
        kind == 0 ? HTTP_REQUEST : kind == 1 ? HTTP_RESPONSE : HTTP_BOTH;
    // settings NULL: this bridge's trampolines replaced api.c's, so the
    // settings table is never consulted.
    llhttp_init(&s->parser, type, NULL);
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_h1_free(long long handle) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    s->magic = 0;
    free(s->events);
    free(s);
    return BEANS_NET_OK;
}

// Corpus-runner knobs: req = [lenient_bitmask, pause_event_type, skip_body].
// Lenient bits follow the llhttp_set_lenient_* order below. The public
// std.http surface never calls this.
BEANS_NET_API long long beans_h1_test_mode(long long handle, const uint64_t* req) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t lenient = beans_net_word(req, 0);
    if (lenient & 1) llhttp_set_lenient_headers(&s->parser, 1);
    if (lenient & 2) llhttp_set_lenient_chunked_length(&s->parser, 1);
    if (lenient & 4) llhttp_set_lenient_keep_alive(&s->parser, 1);
    if (lenient & 8) llhttp_set_lenient_transfer_encoding(&s->parser, 1);
    if (lenient & 16) llhttp_set_lenient_version(&s->parser, 1);
    if (lenient & 32) llhttp_set_lenient_data_after_close(&s->parser, 1);
    if (lenient & 64) llhttp_set_lenient_optional_lf_after_cr(&s->parser, 1);
    if (lenient & 128) llhttp_set_lenient_optional_cr_before_lf(&s->parser, 1);
    if (lenient & 256) llhttp_set_lenient_optional_crlf_after_chunk(&s->parser, 1);
    if (lenient & 512) llhttp_set_lenient_spaces_after_chunk_size(&s->parser, 1);
    if (lenient & 1024) llhttp_set_lenient_header_value_relaxed(&s->parser, 1);
    s->pause_on = (int)beans_net_word(req, 1);
    s->skip_body = (int)beans_net_word(req, 2);
    return BEANS_NET_OK;
}

// Feeds one buffer. Pauses from the pause knob are recorded and resumed
// inside this call; a hard parse error is recorded as an error event and
// latches the session. Returns BEANS_NET_OK unless the handle is bad or
// the buffer arguments are inconsistent.
BEANS_NET_API long long beans_h1_execute(long long handle,
                                         const uint8_t* data,
                                         const uint64_t* req) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len && !data) return BEANS_NET_ERR_INVALID;
    if (len > SIZE_MAX) return BEANS_NET_ERR_RANGE;
    // Feeding nothing is a no-op by definition — and must not reach llhttp:
    // its execute prologue rebases an open span's origin to the new buffer,
    // and a NULL buffer would poison the span a later feed continues.
    if (len == 0) return BEANS_NET_OK;
    if (s->parser.error != 0 && s->parser.error != HPE_PAUSED) {
        // Latched: an errored parser stays errored (llhttp's own contract).
        return BEANS_NET_ERR_CLOSED;
    }
    const char* p = (const char*)data;
    uint64_t remaining = len;
    for (;;) {
        s->chunk = p;
        s->chunk_len = (size_t)remaining;
        llhttp_errno_t err = llhttp_execute(&s->parser, p, (size_t)remaining);
        if (s->out_of_memory) return BEANS_NET_ERR_MEMORY;
        if (err == HPE_OK) {
            beans_h1_flush_span(s);
            s->base += remaining;
            s->chunk = NULL;
            return BEANS_NET_OK;
        }
        const char* stop = llhttp_get_error_pos(&s->parser);
        uint64_t consumed = stop ? (uint64_t)(stop - p) : 0;
        if (err == HPE_PAUSED) {
            beans_h1_plain(s, BEANS_H1_EV_PAUSE, s->base + consumed);
            llhttp_resume(&s->parser);
            s->base += consumed;
            p += consumed;
            remaining -= consumed;
            continue;
        }
        // Upgrade pauses and hard errors both surface as the error event;
        // the Beans layer maps the two pause codes to upgrade handling and
        // everything else to a parse error. Trailing input stays with the
        // caller: base advances to the stop position.
        beans_h1_flush_span(s);
        beans_h1_error_event(s, (int)err, llhttp_get_error_reason(&s->parser),
                             s->base + consumed);
        s->base += consumed;
        s->chunk = NULL;
        return BEANS_NET_OK;
    }
}

// Signals EOF. api.c's llhttp_finish dispatches its completion through the
// settings table this bridge does not use, so the same three-way decision
// is made here against the parser's finish state, recording events instead:
// SAFE_WITH_CB fires message-complete, SAFE is silence, UNSAFE is the
// "Invalid EOF state" error a truncated message earns.
BEANS_NET_API long long beans_h1_finish(long long handle) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    s->chunk = NULL;
    s->chunk_len = 0;
    if (s->parser.error != 0) return BEANS_NET_OK;
    if (s->parser.finish == HTTP_FINISH_SAFE_WITH_CB) {
        beans_h1_plain(s, BEANS_H1_EV_MESSAGE_COMPLETE, s->base);
    } else if (s->parser.finish == HTTP_FINISH_UNSAFE) {
        beans_h1_error_event(s, HPE_INVALID_EOF_STATE, "Invalid EOF state",
                             s->base);
        s->parser.error = HPE_INVALID_EOF_STATE;
    }
    if (s->out_of_memory) return BEANS_NET_ERR_MEMORY;
    beans_h1_flush_span(s);
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_h1_events_size(long long handle) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s) return -1;
    // A span still pending would be invisible; expose its current shape too.
    // feed()/finish() flush before returning, so this only matters if the
    // Beans side drains mid-message — which it does after every feed.
    return (long long)s->events_len;
}

BEANS_NET_API long long beans_h1_take_events(long long handle,
                                             uint8_t* out,
                                             const uint64_t* req) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap < s->events_len) return -1;
    if (s->events_len && out) memcpy(out, s->events, s->events_len);
    long long taken = (long long)s->events_len;
    s->events_len = 0;
    return taken;
}

// The parser's finish-state enum (llhttp_finish_t), for the corpus's finish
// tests: 0 = safe, 1 = safe with cb, 2 = unsafe.
BEANS_NET_API long long beans_h1_finish_state(long long handle) {
    beans_h1_session* s = beans_h1_of(handle);
    if (!s) return -1;
    return (long long)s->parser.finish;
}
