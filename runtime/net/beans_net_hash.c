// Cryptographic hashes for std.crypto — from the platform, never shipped.
//
// SHA-1 for the WebSocket handshake, SHA-256 for everything that comes
// after. Each platform's own crypto library provides them: CommonCrypto on
// macOS, CNG on Windows, and OpenSSL's libcrypto loaded at runtime on
// Linux/BSD. No hash implementation is vendored — a hash is exactly the
// kind of thing you take from the OS rather than carry.
//
// The API is a small streaming digest: new, update, finish. HMAC rides the
// same primitive in the Beans layer (the standard ipad/opad construction),
// so this bridge stays minimal by design.
//
// Algorithms: 0 = SHA-1 (20 bytes), 1 = SHA-256 (32 bytes).
// Statuses follow beans_net_common.h.

#include "beans_net_common.h"

enum {
    BEANS_HASH_SHA1 = 0,
    BEANS_HASH_SHA256 = 1,
};

static long long beans_hash_digest_len(int algorithm) {
    return algorithm == BEANS_HASH_SHA1 ? 20 : 32;
}

// ---- macOS: CommonCrypto ------------------------------------------------------

#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>

typedef struct {
    int algorithm;
    union {
        CC_SHA1_CTX sha1;
        CC_SHA256_CTX sha256;
    } state;
    uint64_t magic;
} beans_hash_session;

#define BEANS_HASH_MAGIC 0x62656e736861ULL

static beans_hash_session* beans_hash_of(long long handle) {
    beans_hash_session* s = (beans_hash_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_HASH_MAGIC) return NULL;
    return s;
}

BEANS_NET_API long long beans_hash_new(long long algorithm) {
    if (algorithm != BEANS_HASH_SHA1 && algorithm != BEANS_HASH_SHA256) return 0;
    beans_hash_session* s = (beans_hash_session*)calloc(1, sizeof(beans_hash_session));
    if (!s) return 0;
    s->algorithm = (int)algorithm;
    if (algorithm == BEANS_HASH_SHA1) {
        CC_SHA1_Init(&s->state.sha1);
    } else {
        CC_SHA256_Init(&s->state.sha256);
    }
    s->magic = BEANS_HASH_MAGIC;
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_hash_update(long long handle, const uint8_t* data,
                                          const uint64_t* req) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_NET_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    // CC_LONG is uint32_t, so a single call cannot carry a buffer of 4 GiB or
    // more. Feeding it `(CC_LONG)len` would hash only `len mod 2^32` bytes and
    // report success -- a 4 GiB input would digest as the empty string. Walk
    // the buffer in chunks that fit instead.
    const CC_LONG step = (CC_LONG)0x40000000; // 1 GiB per call
    while (len > 0) {
        CC_LONG take = len > (uint64_t)step ? step : (CC_LONG)len;
        if (s->algorithm == BEANS_HASH_SHA1) {
            CC_SHA1_Update(&s->state.sha1, data, take);
        } else {
            CC_SHA256_Update(&s->state.sha256, data, take);
        }
        data += take;
        len -= take;
    }
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_hash_finish(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s || !out || !req) return BEANS_NET_ERR_INVALID;
    if (beans_net_word(req, 0) < (uint64_t)beans_hash_digest_len(s->algorithm))
        return BEANS_NET_ERR_RANGE;
    if (s->algorithm == BEANS_HASH_SHA1) {
        CC_SHA1_Final(out, &s->state.sha1);
    } else {
        CC_SHA256_Final(out, &s->state.sha256);
    }
    return beans_hash_digest_len(s->algorithm);
}

BEANS_NET_API long long beans_hash_free(long long handle) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

// ---- Windows: CNG (bcrypt) ----------------------------------------------------

#elif defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>

typedef struct {
    int algorithm;
    BCRYPT_ALG_HANDLE alg;
    BCRYPT_HASH_HANDLE hash;
    uint64_t magic;
} beans_hash_session;

#define BEANS_HASH_MAGIC 0x62656e736861ULL

static beans_hash_session* beans_hash_of(long long handle) {
    beans_hash_session* s = (beans_hash_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_HASH_MAGIC) return NULL;
    return s;
}

BEANS_NET_API long long beans_hash_new(long long algorithm) {
    if (algorithm != BEANS_HASH_SHA1 && algorithm != BEANS_HASH_SHA256) return 0;
    beans_hash_session* s = (beans_hash_session*)calloc(1, sizeof(beans_hash_session));
    if (!s) return 0;
    s->algorithm = (int)algorithm;
    const wchar_t* id = algorithm == BEANS_HASH_SHA1 ? BCRYPT_SHA1_ALGORITHM
                                                     : BCRYPT_SHA256_ALGORITHM;
    if (BCryptOpenAlgorithmProvider(&s->alg, id, NULL, 0) != 0) { free(s); return 0; }
    if (BCryptCreateHash(s->alg, &s->hash, NULL, 0, NULL, 0, 0) != 0) {
        BCryptCloseAlgorithmProvider(s->alg, 0);
        free(s);
        return 0;
    }
    s->magic = BEANS_HASH_MAGIC;
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_hash_update(long long handle, const uint8_t* data,
                                          const uint64_t* req) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_NET_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    // ULONG is 32-bit; see the CommonCrypto path for why a single narrowed
    // call would silently hash the wrong bytes and still report success.
    const ULONG step = (ULONG)0x40000000; // 1 GiB per call
    while (len > 0) {
        ULONG take = len > (uint64_t)step ? step : (ULONG)len;
        if (BCryptHashData(s->hash, (PUCHAR)data, take, 0) != 0)
            return BEANS_NET_ERR_INVALID;
        data += take;
        len -= take;
    }
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_hash_finish(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s || !out || !req) return BEANS_NET_ERR_INVALID;
    long long need = beans_hash_digest_len(s->algorithm);
    if (beans_net_word(req, 0) < (uint64_t)need) return BEANS_NET_ERR_RANGE;
    if (BCryptFinishHash(s->hash, out, (ULONG)need, 0) != 0)
        return BEANS_NET_ERR_INVALID;
    return need;
}

BEANS_NET_API long long beans_hash_free(long long handle) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    BCryptDestroyHash(s->hash);
    BCryptCloseAlgorithmProvider(s->alg, 0);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

// ---- Linux/BSD: OpenSSL libcrypto at runtime ----------------------------------

#else
#include <dlfcn.h>

// EVP is OpenSSL's stable digest interface. Loaded once, lazily, from
// whichever libcrypto the system ships — never linked, so a build needs no
// OpenSSL headers and the binary runs wherever libcrypto.so.3 (or .1.1)
// lives. BEANS_LIBCRYPTO overrides the search for testing on hosts where
// libcrypto lives off the default path (e.g. Homebrew).
typedef void* (*evp_md_ctx_new_fn)(void);
typedef void (*evp_md_ctx_free_fn)(void*);
typedef const void* (*evp_get_fn)(void);
typedef int (*evp_digest_init_fn)(void*, const void*, void*);
typedef int (*evp_digest_update_fn)(void*, const void*, size_t);
typedef int (*evp_digest_final_fn)(void*, unsigned char*, unsigned int*);

static struct {
    int loaded;
    int ok;
    void* handle;
    evp_md_ctx_new_fn ctx_new;
    evp_md_ctx_free_fn ctx_free;
    evp_get_fn sha1;
    evp_get_fn sha256;
    evp_digest_init_fn init;
    evp_digest_update_fn update;
    evp_digest_final_fn final;
} beans_crypto;

static void beans_crypto_load(void) {
    if (beans_crypto.loaded) return;
    beans_crypto.loaded = 1;
    const char* names[6];
    int count = 0;
    const char* override = getenv("BEANS_LIBCRYPTO");
    if (override && *override) names[count++] = override;
    names[count++] = "libcrypto.so.3";
    names[count++] = "libcrypto.so.1.1";
    names[count++] = "libcrypto.so";
    names[count++] = "libcrypto.dylib";
    names[count++] = "libcrypto.3.dylib";
    void* h = NULL;
    for (int i = 0; i < count; i++) {
        h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (h) break;
    }
    if (!h) return;
    beans_crypto.handle = h;
    beans_crypto.ctx_new = (evp_md_ctx_new_fn)dlsym(h, "EVP_MD_CTX_new");
    beans_crypto.ctx_free = (evp_md_ctx_free_fn)dlsym(h, "EVP_MD_CTX_free");
    beans_crypto.sha1 = (evp_get_fn)dlsym(h, "EVP_sha1");
    beans_crypto.sha256 = (evp_get_fn)dlsym(h, "EVP_sha256");
    beans_crypto.init = (evp_digest_init_fn)dlsym(h, "EVP_DigestInit_ex");
    beans_crypto.update = (evp_digest_update_fn)dlsym(h, "EVP_DigestUpdate");
    beans_crypto.final = (evp_digest_final_fn)dlsym(h, "EVP_DigestFinal_ex");
    beans_crypto.ok = beans_crypto.ctx_new && beans_crypto.ctx_free &&
                      beans_crypto.sha1 && beans_crypto.sha256 &&
                      beans_crypto.init && beans_crypto.update &&
                      beans_crypto.final;
}

typedef struct {
    int algorithm;
    void* ctx;
    uint64_t magic;
} beans_hash_session;

#define BEANS_HASH_MAGIC 0x62656e736861ULL

static beans_hash_session* beans_hash_of(long long handle) {
    beans_hash_session* s = (beans_hash_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_HASH_MAGIC) return NULL;
    return s;
}

BEANS_NET_API long long beans_hash_new(long long algorithm) {
    if (algorithm != BEANS_HASH_SHA1 && algorithm != BEANS_HASH_SHA256) return 0;
    beans_crypto_load();
    if (!beans_crypto.ok) return 0;
    beans_hash_session* s = (beans_hash_session*)calloc(1, sizeof(beans_hash_session));
    if (!s) return 0;
    s->algorithm = (int)algorithm;
    s->ctx = beans_crypto.ctx_new();
    if (!s->ctx) { free(s); return 0; }
    const void* md = algorithm == BEANS_HASH_SHA1 ? beans_crypto.sha1()
                                                  : beans_crypto.sha256();
    if (beans_crypto.init(s->ctx, md, NULL) != 1) {
        beans_crypto.ctx_free(s->ctx);
        free(s);
        return 0;
    }
    s->magic = BEANS_HASH_MAGIC;
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_hash_update(long long handle, const uint8_t* data,
                                          const uint64_t* req) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_NET_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    if (beans_crypto.update(s->ctx, data, (size_t)len) != 1)
        return BEANS_NET_ERR_INVALID;
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_hash_finish(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s || !out || !req) return BEANS_NET_ERR_INVALID;
    long long need = beans_hash_digest_len(s->algorithm);
    if (beans_net_word(req, 0) < (uint64_t)need) return BEANS_NET_ERR_RANGE;
    unsigned int written = 0;
    if (beans_crypto.final(s->ctx, out, &written) != 1)
        return BEANS_NET_ERR_INVALID;
    return (long long)written;
}

BEANS_NET_API long long beans_hash_free(long long handle) {
    beans_hash_session* s = beans_hash_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    beans_crypto.ctx_free(s->ctx);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

#endif

// Is a platform hash provider available? The Linux backend can fail if no
// libcrypto is present; mac and Windows always have one.
BEANS_NET_API long long beans_hash_available(void) {
#if defined(__APPLE__) || defined(_WIN32)
    return 1;
#else
    beans_crypto_load();
    return beans_crypto.ok ? 1 : 0;
#endif
}
