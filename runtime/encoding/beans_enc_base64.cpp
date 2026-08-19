// std.encoding.base64 native bridge over simdutf (vendored, see
// vendor/VENDOR.md). Compiled as C++17 with no exceptions and no RTTI, in
// upstream's SIMDUTF_NO_LIBCXX mode: the object references no C++ runtime
// symbol at all, so programs keep linking through the plain C driver with no
// C++ standard library and no Beans-written shim.
//
// ABI shape (shared by every encoding bridge): payload buffers cross as
// direct RawPtr parameters and everything else — lengths, flags, outputs —
// rides in a RawPtr<u64> request buffer. Interpreter compatibility forces
// this split: both interpreters give extern "C" calls a real host copy of
// each RawPtr *argument*, but a pointer value smuggled through an integer
// word would be a synthetic interpreter address no C code can touch. Handles
// that C itself returned are opaque and safe to embed.
//
// The amalgamated simdutf is included with every feature except base64
// disabled: the object stays small and the SIMD kernels plus the scalar
// fallback for targets with no vector unit all come from upstream unchanged.

#include "beans_enc_common.h"

// Upstream's supported mode for building without a C++ standard library:
// it removes the function-local static in the implementation dispatch and
// supplies its own weak __cxa_pure_virtual, leaving an object whose only
// undefined symbols are libc's. No Beans-written C++ runtime shim is needed
// here; test/encoding_symbols.sh enforces that.
#define SIMDUTF_NO_LIBCXX 1
#define SIMDUTF_FEATURE_DETECT_ENCODING 0
#define SIMDUTF_FEATURE_ASCII 0
#define SIMDUTF_FEATURE_LATIN1 0
#define SIMDUTF_FEATURE_UTF8 0
#define SIMDUTF_FEATURE_UTF16 0
#define SIMDUTF_FEATURE_UTF32 0
#define SIMDUTF_FEATURE_BASE64 1
// simdutf's PPC64 kernel uses VSX instructions. The big-endian ppc64 target
// keeps the older portable CPU baseline, so select the scalar kernel there.
#if defined(__powerpc64__) && !defined(__VSX__)
#define SIMDUTF_IMPLEMENTATION_PPC64 0
#define SIMDUTF_IMPLEMENTATION_FALLBACK 1
#endif
#include "vendor/simdutf/simdutf.cpp"

// Encoding ids shared with base64.b.
enum {
    BEANS_B64_STANDARD = 0,        // RFC 4648 section 4, padded
    BEANS_B64_STANDARD_NO_PAD = 1, // RFC 4648 section 4, no padding
    BEANS_B64_URL = 2,             // RFC 4648 section 5, padded
    BEANS_B64_URL_NO_PAD = 3,      // RFC 4648 section 5, no padding
};

// Decode error kinds shared with base64.b.
enum {
    BEANS_B64_ERR_INVALID_CHAR = 1,
    BEANS_B64_ERR_BAD_LENGTH = 2,
    BEANS_B64_ERR_BAD_PADDING = 3,
    BEANS_B64_ERR_EXTRA_BITS = 4,
    BEANS_B64_ERR_WHITESPACE = 5,
    BEANS_B64_ERR_OTHER = 6,
};

static simdutf::base64_options beans_enc_b64_options(uint64_t encoding) {
    switch (encoding) {
    case BEANS_B64_STANDARD: return simdutf::base64_default;
    case BEANS_B64_STANDARD_NO_PAD: return simdutf::base64_default_no_padding;
    case BEANS_B64_URL: return simdutf::base64_url_with_padding;
    default: return simdutf::base64_url;
    }
}

static int beans_enc_b64_map_error(simdutf::error_code code) {
    switch (code) {
    case simdutf::INVALID_BASE64_CHARACTER: return BEANS_B64_ERR_INVALID_CHAR;
    case simdutf::BASE64_INPUT_REMAINDER: return BEANS_B64_ERR_BAD_LENGTH;
    case simdutf::BASE64_EXTRA_BITS: return BEANS_B64_ERR_EXTRA_BITS;
    default: return BEANS_B64_ERR_OTHER;
    }
}

// RFC 4648 places whitespace outside the alphabet, so strict mode must
// reject it; simdutf always skips ASCII whitespace. Find the first
// whitespace byte with memchr (SIMD-fast in every libc) so the strict path
// stays allocation-free and never walks the input byte-by-byte in Beans.
static long long beans_enc_b64_find_whitespace(const char* src, size_t len) {
    static const char spaces[5] = {' ', '\t', '\n', '\r', '\f'};
    const char* first = NULL;
    for (int i = 0; i < 5; i++) {
        const char* hit = (const char*)memchr(src, spaces[i], len);
        if (hit && (!first || hit < first)) first = hit;
    }
    if (!first) return -1;
    return (long long)(first - src);
}

static unsigned int beans_enc_b64_value(unsigned char byte) {
    if (byte >= 'A' && byte <= 'Z') return (unsigned int)(byte - 'A');
    if (byte >= 'a' && byte <= 'z') return (unsigned int)(byte - 'a' + 26);
    if (byte >= '0' && byte <= '9') return (unsigned int)(byte - '0' + 52);
    if (byte == '+' || byte == '-') return 62;
    return 63; // '/' or '_'; the codec already rejected every other byte
}

extern "C" {

// Exact encoded size for `len` payload bytes under `encoding`.
BEANS_ENC_API long long beans_enc_b64_encoded_len(long long encoding, long long len) {
    return (long long)simdutf::base64_length_from_binary(
        (size_t)len, beans_enc_b64_options((uint64_t)encoding));
}

// Upper bound for the decoded size of `len` base64 characters. The exact
// count comes back from decode; the Beans side shrinks its buffer to it.
BEANS_ENC_API long long beans_enc_b64_max_decoded_len(long long len) {
    return (long long)(((size_t)len / 4 + 1) * 3);
}

// req[0]=src len, req[1]=dst capacity, req[2]=encoding.
// Returns bytes written, or -1 if the capacity is smaller than the exact
// encoded length. simdutf writes directly into dst.
BEANS_ENC_API long long beans_enc_b64_encode(unsigned char* src, unsigned char* dst,
                                             uint64_t* req) {
    size_t len = (size_t)req[0];
    size_t cap = (size_t)req[1];
    simdutf::base64_options options = beans_enc_b64_options(req[2]);
    size_t need = simdutf::base64_length_from_binary(len, options);
    if (cap < need) return -1;
    return (long long)simdutf::binary_to_base64((const char*)src, len,
                                                (char*)dst, options);
}

// req[0]=src len, req[1]=dst capacity, req[2]=encoding,
// req[3]=mode (0 strict, 1 forgiving)
// out: req[4]=bytes written, req[5]=error byte offset
//
// Strict follows RFC 4648 for the chosen encoding: a padded encoding
// requires exact padding, an unpadded one refuses '=' entirely, the
// trailing padding bits of a partial final group must be zero, and any
// byte outside the alphabet — whitespace included — is an error. Forgiving
// follows the WHATWG forgiving-base64 shape: ASCII whitespace is skipped, a
// partial final group is accepted with or without padding, and non-zero
// trailing padding bits are ignored; bytes outside the alphabet are still
// errors.
//
// simdutf's `strict` mirrors the TC39 rule that a partial final group must
// be padded. For an RFC 4648 unpadded encoding, decode the partial group with
// `loose` and check its unused bits here. This avoids copying and decoding the
// entire input a second time just to validate its last two or three bytes.
BEANS_ENC_API long long beans_enc_b64_decode(unsigned char* src, unsigned char* dst,
                                             uint64_t* req) {
    size_t len = (size_t)req[0];
    uint64_t encoding = req[2];
    uint64_t forgiving = req[3];
    req[4] = 0;
    req[5] = 0;
    simdutf::base64_options options = beans_enc_b64_options(encoding);
    int padded_encoding = encoding == BEANS_B64_STANDARD || encoding == BEANS_B64_URL;
    simdutf::last_chunk_handling_options chunk =
        forgiving ? simdutf::loose : simdutf::strict;
    if (!forgiving) {
        long long space = beans_enc_b64_find_whitespace((const char*)src, len);
        if (space >= 0) {
            req[5] = (uint64_t)space;
            return BEANS_B64_ERR_WHITESPACE;
        }
        if (!padded_encoding) {
            const char* pad = (const char*)memchr(src, '=', len);
            if (pad) {
                req[5] = (uint64_t)((const unsigned char*)pad - src);
                return BEANS_B64_ERR_BAD_PADDING;
            }
            chunk = simdutf::loose;
        }
    }
    simdutf::result outcome = simdutf::base64_to_binary(
        (const char*)src, len, (char*)dst, options, chunk);
    if (!forgiving && !padded_encoding &&
        outcome.error == simdutf::SUCCESS && len > 0) {
        size_t remainder = len & 3;
        unsigned int unused_mask = remainder == 2 ? 15 : remainder == 3 ? 3 : 0;
        if (unused_mask && (beans_enc_b64_value(src[len - 1]) & unused_mask)) {
            req[5] = (uint64_t)(len - 1);
            return BEANS_B64_ERR_EXTRA_BITS;
        }
    }
    if (outcome.error != simdutf::SUCCESS) {
        req[5] = (uint64_t)outcome.count;
        int mapped = beans_enc_b64_map_error(outcome.error);
        // A '=' where this encoding does not allow one is a padding
        // problem, not an alphabet problem.
        if (mapped == BEANS_B64_ERR_INVALID_CHAR && outcome.count < len &&
            src[outcome.count] == '=') {
            mapped = BEANS_B64_ERR_BAD_PADDING;
        }
        return mapped;
    }
    req[4] = (uint64_t)outcome.count;
    return BEANS_ENC_OK;
}

} // extern "C"
