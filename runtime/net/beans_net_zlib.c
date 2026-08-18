// DEFLATE for std.compress — zlib-ng in compat mode, generic lane.
//
// The vendored tree compiles beside this shim as separate translation
// units (zlib-ng shares static helper names across files); the generated
// compat headers live in runtime/net/zlib-config, produced once by
// upstream's cmake with ZLIB_COMPAT=ON WITH_OPTIM=OFF and portable-ized by
// hand where the generator baked in a host fact (documented in VENDOR.md).
// The compat API also keeps the door open: any target where zlib-ng proves
// painful can fall back to a system zlib without touching this file's
// callers.
//
// Everything here is bounded. One-shot inflate takes a mandatory output
// capacity and reports crossing it as its own status — a decompression
// bomb is an API impossibility, not a caller's afterthought. Streams carry
// their counters on the Beans side, which enforces the same rule per
// Inflater.
//
// Statuses: BEANS_NET_* for argument problems, plus
//   100 corrupt stream, 101 output cap exceeded, 102 truncated input.

#include "beans_net_common.h"

#include "zlib.h"

enum {
    BEANS_ZLIB_CORRUPT = 100,
    BEANS_ZLIB_CAP = 101,
    BEANS_ZLIB_TRUNCATED = 102,
};

// format: 0 = zlib wrapper, 1 = raw deflate, 2 = gzip wrapper.
static int beans_zlib_window_bits(uint64_t format, int inflating) {
    if (format == 1) return -15;
    if (format == 2) return inflating ? 15 + 16 : 15 + 16;
    return 15;
}

// A conservative output bound for one-shot deflate of `len` bytes.
BEANS_NET_API long long beans_zlib_bound(long long len, long long format) {
    if (len < 0) return -1;
    uLong bound = compressBound((uLong)len);
    // compressBound speaks for the zlib wrapper; gzip adds a 10-byte
    // header and an 8-byte trailer beyond it.
    return (long long)bound + (format == 2 ? 18 : 0);
}

// req: [0] srclen, [1] dstcap, [2] level (0..9, 6 default), [3] format;
// req[4] receives the written size.
BEANS_NET_API long long beans_zlib_deflate(const uint8_t* src,
                                           uint8_t* dst,
                                           uint64_t* req) {
    if (!req || (!src && req[0]) || !dst) return BEANS_NET_ERR_INVALID;
    z_stream stream;
    memset(&stream, 0, sizeof stream);
    int level = (int)req[2];
    if (level < 0 || level > 9) level = 6;
    if (deflateInit2(&stream, level, Z_DEFLATED,
                     beans_zlib_window_bits(req[3], 0), 8,
                     Z_DEFAULT_STRATEGY) != Z_OK)
        return BEANS_NET_ERR_MEMORY;
    stream.next_in = (z_const Bytef*)src;
    stream.avail_in = (uInt)req[0];
    stream.next_out = dst;
    stream.avail_out = (uInt)req[1];
    int rc = deflate(&stream, Z_FINISH);
    long long written = (long long)stream.total_out;
    deflateEnd(&stream);
    if (rc != Z_STREAM_END) {
        // The only way FINISH fails with valid input is a short buffer.
        return BEANS_ZLIB_CAP;
    }
    req[4] = (uint64_t)written;
    return BEANS_NET_OK;
}

// req: [0] srclen, [1] dstcap (the mandatory bound), [2] format;
// req[3] receives the written size. gzip inputs may hold several members;
// all of them decode, matching what `gzip -d` does with concatenated files.
BEANS_NET_API long long beans_zlib_inflate(const uint8_t* src,
                                           uint8_t* dst,
                                           uint64_t* req) {
    if (!req || (!src && req[0]) || (!dst && req[1])) return BEANS_NET_ERR_INVALID;
    z_stream stream;
    memset(&stream, 0, sizeof stream);
    if (inflateInit2(&stream, beans_zlib_window_bits(req[2], 1)) != Z_OK)
        return BEANS_NET_ERR_MEMORY;
    stream.next_in = (z_const Bytef*)src;
    stream.avail_in = (uInt)req[0];
    stream.next_out = dst;
    stream.avail_out = (uInt)req[1];
    int gzip = req[2] == 2;
    uint64_t member_bytes = 0; // completed members; reset zeroes total_out
    for (;;) {
        int rc = inflate(&stream, Z_NO_FLUSH);
        if (rc == Z_STREAM_END) {
            if (gzip && stream.avail_in > 0) {
                // Another member follows; keep the output cursor and
                // continue, exactly like a concatenated .gz file.
                member_bytes += (uint64_t)stream.total_out;
                if (inflateReset(&stream) != Z_OK) break;
                continue;
            }
            req[3] = member_bytes + (uint64_t)stream.total_out;
            inflateEnd(&stream);
            return BEANS_NET_OK;
        }
        if (rc == Z_OK) {
            if (stream.avail_out == 0) {
                inflateEnd(&stream);
                return BEANS_ZLIB_CAP;
            }
            if (stream.avail_in == 0) {
                inflateEnd(&stream);
                return BEANS_ZLIB_TRUNCATED;
            }
            continue;
        }
        if (rc == Z_BUF_ERROR) {
            int out_full = stream.avail_out == 0;
            inflateEnd(&stream);
            return out_full ? BEANS_ZLIB_CAP : BEANS_ZLIB_TRUNCATED;
        }
        break;
    }
    inflateEnd(&stream);
    return BEANS_ZLIB_CORRUPT;
}

// ---- streaming ----------------------------------------------------------------

typedef struct {
    z_stream stream;
    int inflating;
    uint64_t magic;
} beans_zlib_session;

#define BEANS_ZLIB_MAGIC 0x62656e737a6c6962ULL

static beans_zlib_session* beans_zlib_of(long long handle) {
    beans_zlib_session* s = (beans_zlib_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_ZLIB_MAGIC) return NULL;
    return s;
}

// req: [0] kind (0 deflate, 1 inflate), [1] format, [2] level.
BEANS_NET_API long long beans_zlib_stream_new(const uint64_t* req) {
    if (!req) return 0;
    beans_zlib_session* s =
        (beans_zlib_session*)calloc(1, sizeof(beans_zlib_session));
    if (!s) return 0;
    s->inflating = req[0] == 1;
    int rc;
    if (s->inflating) {
        rc = inflateInit2(&s->stream, beans_zlib_window_bits(req[1], 1));
    } else {
        int level = (int)req[2];
        if (level < 0 || level > 9) level = 6;
        rc = deflateInit2(&s->stream, level, Z_DEFLATED,
                          beans_zlib_window_bits(req[1], 0), 8,
                          Z_DEFAULT_STRATEGY);
    }
    if (rc != Z_OK) {
        free(s);
        return 0;
    }
    s->magic = BEANS_ZLIB_MAGIC;
    return (long long)(intptr_t)s;
}

// One streaming step.
// req: [0] handle, [1] srclen, [2] dstcap, [3] flush (0 none, 1 sync,
// 2 finish); results written back: [4] consumed, [5] produced,
// [6] 1 when the stream reached its end.
BEANS_NET_API long long beans_zlib_stream_run(const uint8_t* src,
                                              uint8_t* dst,
                                              uint64_t* req) {
    if (!req) return BEANS_NET_ERR_INVALID;
    beans_zlib_session* s = beans_zlib_of((long long)req[0]);
    if (!s) return BEANS_NET_ERR_CLOSED;
    if ((!src && req[1]) || (!dst && req[2])) return BEANS_NET_ERR_INVALID;
    s->stream.next_in = (z_const Bytef*)src;
    s->stream.avail_in = (uInt)req[1];
    s->stream.next_out = dst;
    s->stream.avail_out = (uInt)req[2];
    int flush = req[3] == 2 ? Z_FINISH : req[3] == 1 ? Z_SYNC_FLUSH : Z_NO_FLUSH;
    int rc = s->inflating ? inflate(&s->stream, Z_NO_FLUSH)
                          : deflate(&s->stream, flush);
    req[4] = req[1] - s->stream.avail_in;
    req[5] = req[2] - s->stream.avail_out;
    req[6] = rc == Z_STREAM_END ? 1 : 0;
    if (rc == Z_OK || rc == Z_STREAM_END) return BEANS_NET_OK;
    if (rc == Z_BUF_ERROR) {
        // No progress possible with these buffers — not corruption. The
        // Beans side distinguishes "give me more input" from "give me more
        // room" by the counters it already has.
        return BEANS_NET_OK;
    }
    return s->inflating ? BEANS_ZLIB_CORRUPT : BEANS_NET_ERR_INVALID;
}

BEANS_NET_API long long beans_zlib_stream_free(long long handle) {
    beans_zlib_session* s = beans_zlib_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->inflating) {
        inflateEnd(&s->stream);
    } else {
        deflateEnd(&s->stream);
    }
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}
