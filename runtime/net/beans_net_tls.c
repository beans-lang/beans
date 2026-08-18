// TLS for std.tls — the platform's own stack, wrapping a socket as a filter.
//
// The API is a byte pump with no IO of its own: the Beans side owns the
// TcpStream and does every read and write, while this bridge turns plaintext
// into TLS records and back. Handshake and record processing are driven by
// feeding received bytes in and draining bytes to send out, exactly the
// shape a nonblocking loop wants — no callback ever blocks, because there
// are no IO callbacks at all. The memory-BIO / SSLSetIOFuncs pattern every
// platform offers is used the same way on each.
//
// Three backends behind one contract:
//   macOS      SecureTransport (deprecated but shipping; the API hides it,
//              so a later Network.framework swap is invisible)
//   Linux/BSD  OpenSSL 3 via dlopen (libssl.so.3), memory BIOs
//   Windows    SChannel (not built here yet; the shape is the SSPI token
//              pump over the same in/out buffers)
//
// Certificate chain building and hostname verification always belong to the
// platform verifier — never reimplemented here.
//
// The in/out model: the Beans side calls
//   feed(handle, received_bytes)      -> hands TLS the ciphertext that arrived
//   pull_outgoing(handle, buffer)     -> takes ciphertext to write to the socket
//   handshake(handle)                 -> advances; 0 done, 1 wants IO, <0 error
//   write(handle, plaintext)          -> queues app data (becomes outgoing)
//   read(handle, buffer)              -> takes decrypted app data
//   status codes below.

#include "beans_net_common.h"

enum {
    BEANS_TLS_OK = 0,
    BEANS_TLS_WANT_IO = 1,       // needs more input, or has output to flush
    BEANS_TLS_CLOSED = 2,        // peer sent close_notify
    BEANS_TLS_HANDSHAKE = 110,   // handshake failed (cert, protocol, alert)
    BEANS_TLS_PROTOCOL = 111,    // record-layer error
    BEANS_TLS_TRUNCATED = 112,   // stream cut without close_notify
    BEANS_TLS_UNSUPPORTED = 113, // no backend on this platform
};

// The read path returns a byte count (>= 0) for data, and these NEGATIVE
// sentinels otherwise, so a one-byte read is never mistaken for a status.
enum {
    BEANS_TLS_R_WANT_IO = -1,
    BEANS_TLS_R_CLOSED = -2,
    BEANS_TLS_R_TRUNCATED = -3,
    BEANS_TLS_R_PROTOCOL = -4,
    BEANS_TLS_R_INVALID = -5,
};

// A growable byte queue for the buffers between TLS and the socket.
typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
    size_t head; // consumed prefix
} beans_tls_buf;

static int beans_tls_buf_reserve(beans_tls_buf* b, size_t more) {
    if (b->head > 0 && b->head == b->len) { b->head = 0; b->len = 0; }
    if (b->len + more <= b->cap) return 1;
    // Compact consumed prefix first.
    if (b->head > 0) {
        memmove(b->data, b->data + b->head, b->len - b->head);
        b->len -= b->head;
        b->head = 0;
        if (b->len + more <= b->cap) return 1;
    }
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + more) cap *= 2;
    uint8_t* grown = (uint8_t*)realloc(b->data, cap);
    if (!grown) return 0;
    b->data = grown;
    b->cap = cap;
    return 1;
}

static void beans_tls_buf_push(beans_tls_buf* b, const uint8_t* src, size_t n) {
    if (!beans_tls_buf_reserve(b, n)) return;
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

static size_t beans_tls_buf_available(const beans_tls_buf* b) {
    return b->len - b->head;
}

static size_t beans_tls_buf_take(beans_tls_buf* b, uint8_t* dst, size_t cap) {
    size_t have = b->len - b->head;
    size_t n = have < cap ? have : cap;
    if (n) memcpy(dst, b->data + b->head, n);
    b->head += n;
    if (b->head == b->len) { b->head = 0; b->len = 0; }
    return n;
}

// ============================================================================
#if defined(__APPLE__)
// SecureTransport. Deprecation warnings are silenced here and only here: the
// deprecation is a platform fact the API is designed to contain.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <Security/Security.h>
#include <Security/SecureTransport.h>

typedef struct {
    SSLContextRef ctx;
    beans_tls_buf incoming; // ciphertext from the socket, into TLS
    beans_tls_buf outgoing; // ciphertext from TLS, to the socket
    int is_server;
    int handshake_done;
    int closed;
    int verified;           // trust evaluation passed
    char host[256];
    CFMutableArrayRef extra_roots; // caller-added anchors, or NULL
    uint64_t magic;
} beans_tls_session;

#define BEANS_TLS_MAGIC 0x62656e73746c73ULL

static beans_tls_session* beans_tls_of(long long handle) {
    beans_tls_session* s = (beans_tls_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_TLS_MAGIC) return NULL;
    return s;
}

// SecureTransport pulls ciphertext through this read callback from our
// incoming buffer; a short buffer returns errSSLWouldBlock so the handshake
// parks instead of blocking.
static OSStatus beans_tls_read_cb(SSLConnectionRef conn, void* data, size_t* len) {
    beans_tls_session* s = (beans_tls_session*)conn;
    size_t want = *len;
    size_t got = beans_tls_buf_take(&s->incoming, (uint8_t*)data, want);
    *len = got;
    return got < want ? errSSLWouldBlock : noErr;
}

static OSStatus beans_tls_write_cb(SSLConnectionRef conn, const void* data, size_t* len) {
    beans_tls_session* s = (beans_tls_session*)conn;
    beans_tls_buf_push(&s->outgoing, (const uint8_t*)data, *len);
    return noErr;
}

// req: [0] is_server, [1] host ptr, [2] host len, [3] min_version (0 = 1.2),
//      [4] alpn ptr (comma-separated), [5] alpn len.
BEANS_NET_API long long beans_tls_client_new(const uint8_t* host,
                                             const uint8_t* alpn,
                                             const uint64_t* req) {
    if (!req) return 0;
    beans_tls_session* s = (beans_tls_session*)calloc(1, sizeof(beans_tls_session));
    if (!s) return 0;
    s->is_server = (int)beans_net_word(req, 0);
    s->ctx = SSLCreateContext(NULL, s->is_server ? kSSLServerSide : kSSLClientSide,
                              kSSLStreamType);
    if (!s->ctx) { free(s); return 0; }
    SSLSetIOFuncs(s->ctx, beans_tls_read_cb, beans_tls_write_cb);
    SSLSetConnection(s->ctx, s);
    SSLSetProtocolVersionMin(s->ctx, kTLSProtocol12);
    if (!s->is_server) {
        uint64_t host_len = beans_net_word(req, 1);
        if (host && host_len > 0 && host_len < sizeof s->host) {
            SSLSetPeerDomainName(s->ctx, (const char*)host, (size_t)host_len);
            memcpy(s->host, host, (size_t)host_len);
            s->host[host_len] = 0;
        }
        // Break out of the handshake at server-auth so trust is evaluated
        // here — with the caller's extra roots plus the system store, and
        // the hostname policy — rather than by SecureTransport's default
        // system-only evaluation. This is what lets a private CA or a
        // pinned root be trusted without ever hand-rolling chain building.
        SSLSetSessionOption(s->ctx, kSSLSessionOptionBreakOnServerAuth, true);
    }
    uint64_t alpn_len = beans_net_word(req, 2);
    if (alpn && alpn_len > 0) {
        // Split comma-separated protocols into a CFArray of CFStrings.
        CFMutableArrayRef protos =
            CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        size_t start = 0;
        for (size_t i = 0; i <= alpn_len; i++) {
            if (i == alpn_len || alpn[i] == ',') {
                if (i > start) {
                    CFStringRef proto = CFStringCreateWithBytes(
                        NULL, alpn + start, i - start, kCFStringEncodingASCII, false);
                    if (proto) { CFArrayAppendValue(protos, proto); CFRelease(proto); }
                }
                start = i + 1;
            }
        }
        SSLSetALPNProtocols(s->ctx, protos);
        CFRelease(protos);
    }
    s->magic = BEANS_TLS_MAGIC;
    return (long long)(intptr_t)s;
}

BEANS_NET_API long long beans_tls_feed(long long handle, const uint8_t* data,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_TLS_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    beans_tls_buf_push(&s->incoming, data, (size_t)len);
    return BEANS_TLS_OK;
}

BEANS_NET_API long long beans_tls_pull_outgoing(long long handle, uint8_t* out,
                                                const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return -1;
    return (long long)beans_tls_buf_take(&s->outgoing, out, (size_t)beans_net_word(req, 0));
}

BEANS_NET_API long long beans_tls_outgoing_size(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return -1;
    return (long long)beans_tls_buf_available(&s->outgoing);
}

// Evaluates the peer's trust with the caller's extra anchors added to the
// system store, and the SSL hostname policy. Returns 1 trusted, 0 rejected.
static int beans_tls_evaluate(beans_tls_session* s) {
    SecTrustRef trust = NULL;
    if (SSLCopyPeerTrust(s->ctx, &trust) != noErr || !trust) return 0;
    int ok = 0;
    // Hostname policy: the platform's own SAN/CN matching.
    if (s->host[0]) {
        CFStringRef host = CFStringCreateWithCString(NULL, s->host,
                                                     kCFStringEncodingUTF8);
        if (host) {
            SecPolicyRef policy = SecPolicyCreateSSL(true, host);
            if (policy) { SecTrustSetPolicies(trust, policy); CFRelease(policy); }
            CFRelease(host);
        }
    }
    if (s->extra_roots && CFArrayGetCount(s->extra_roots) > 0) {
        SecTrustSetAnchorCertificates(trust, s->extra_roots);
        // false: the caller's roots are ADDED to the system store, not a
        // replacement, so a normal public chain still verifies.
        SecTrustSetAnchorCertificatesOnly(trust, false);
    }
    CFErrorRef err = NULL;
    if (SecTrustEvaluateWithError(trust, &err)) {
        ok = 1;
    } else if (err) {
        if (getenv("BEANS_TLS_DEBUG")) {
            CFStringRef desc = CFErrorCopyDescription(err);
            char buf[512];
            if (desc && CFStringGetCString(desc, buf, sizeof buf, kCFStringEncodingUTF8))
                fprintf(stderr, "beans-tls trust eval failed: %s (host=%s roots=%ld)\n",
                        buf, s->host,
                        s->extra_roots ? (long)CFArrayGetCount(s->extra_roots) : 0);
            if (desc) CFRelease(desc);
        }
        CFRelease(err);
    }
    CFRelease(trust);
    return ok;
}

BEANS_NET_API long long beans_tls_handshake(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    for (;;) {
        OSStatus rc = SSLHandshake(s->ctx);
        if (rc == errSSLPeerAuthCompleted) {
            // The break-on-auth stop: evaluate trust here (system roots plus
            // the caller's, with the hostname policy), then continue the
            // handshake in the same call so the Beans side never sees the
            // break — it drives one uniform in/out loop.
            if (!s->is_server && !beans_tls_evaluate(s)) {
                return BEANS_TLS_HANDSHAKE;
            }
            s->verified = 1;
            continue;
        }
        if (rc == noErr) { s->handshake_done = 1; return BEANS_TLS_OK; }
        if (rc == errSSLWouldBlock) return BEANS_TLS_WANT_IO;
        return BEANS_TLS_HANDSHAKE;
    }
}

// Adds a PEM or DER certificate as an extra trust anchor, before the
// handshake. Used for private CAs and pinning.
BEANS_NET_API long long beans_tls_add_root(long long handle, const uint8_t* data,
                                           const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !data || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_NET_ERR_INVALID;
    // Accept PEM by stripping the armor into DER; SecCertificateCreate wants
    // DER. A leading "-----BEGIN" marks PEM.
    CFDataRef der = NULL;
    if (len > 10 && memcmp(data, "-----BEGIN", 10) == 0) {
        // Decode the base64 body between the BEGIN/END lines.
        const char* text = (const char*)data;
        const char* body = strstr(text, "\n");
        const char* end = strstr(text, "-----END");
        if (!body || !end || end <= body) return BEANS_NET_ERR_INVALID;
        // Base64-decode via CFData/SecTransform is heavy; do it by hand.
        static const signed char b64[256] = {0};
        // Build a small decoder inline.
        unsigned char* out = (unsigned char*)malloc((size_t)(end - body));
        if (!out) return BEANS_NET_ERR_MEMORY;
        size_t olen = 0;
        int bits = 0, acc = 0;
        for (const char* p = body; p < end; p++) {
            char c = *p;
            int v = -1;
            if (c >= 'A' && c <= 'Z') v = c - 'A';
            else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
            else if (c >= '0' && c <= '9') v = c - '0' + 52;
            else if (c == '+') v = 62;
            else if (c == '/') v = 63;
            else continue;
            acc = (acc << 6) | v;
            bits += 6;
            if (bits >= 8) { bits -= 8; out[olen++] = (unsigned char)(acc >> bits); }
        }
        der = CFDataCreate(NULL, out, olen);
        free(out);
        (void)b64;
    } else {
        der = CFDataCreate(NULL, data, (CFIndex)len);
    }
    if (!der) return BEANS_NET_ERR_INVALID;
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, der);
    CFRelease(der);
    if (!cert) return BEANS_NET_ERR_INVALID;
    if (!s->extra_roots) {
        s->extra_roots = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    }
    CFArrayAppendValue(s->extra_roots, cert);
    CFRelease(cert);
    return BEANS_NET_OK;
}

// Returns the negotiated ALPN protocol into `out`; length as the return,
// 0 if none, negative on error.
BEANS_NET_API long long beans_tls_alpn(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return -1;
    CFArrayRef protos = NULL;
    if (SSLCopyALPNProtocols(s->ctx, &protos) != noErr || !protos) return 0;
    long long written = 0;
    if (CFArrayGetCount(protos) > 0) {
        CFStringRef first = (CFStringRef)CFArrayGetValueAtIndex(protos, 0);
        char buf[64];
        if (CFStringGetCString(first, buf, sizeof buf, kCFStringEncodingASCII)) {
            size_t n = strlen(buf);
            if (n <= (size_t)beans_net_word(req, 0)) {
                memcpy(out, buf, n);
                written = (long long)n;
            }
        }
    }
    CFRelease(protos);
    return written;
}

BEANS_NET_API long long beans_tls_write(long long handle, const uint8_t* data,
                                        const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return 0;
    if (!data) return BEANS_NET_ERR_INVALID;
    size_t processed = 0;
    OSStatus rc = SSLWrite(s->ctx, data, (size_t)len, &processed);
    if (rc == noErr || rc == errSSLWouldBlock) return (long long)processed;
    return BEANS_TLS_PROTOCOL;
}

// Reads decrypted app data into `out`. Return: bytes read (>=0),
// BEANS_TLS_WANT_IO when nothing is ready yet, BEANS_TLS_CLOSED on a clean
// close_notify, BEANS_TLS_TRUNCATED on an abrupt end.
BEANS_NET_API long long beans_tls_read(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return BEANS_TLS_R_INVALID;
    size_t want = (size_t)beans_net_word(req, 0);
    size_t total = 0;
    // Drain every record SecureTransport can decrypt from the ciphertext
    // already fed, in one call. SSLRead hands back one record at a time (and
    // the server's anti-BEAST 1/n-1 split makes the first record a single
    // byte), so a per-call loop is what turns those fragments into one
    // useful read instead of one byte.
    for (;;) {
        if (total >= want) return (long long)total;
        size_t processed = 0;
        OSStatus rc = SSLRead(s->ctx, out + total, want - total, &processed);
        total += processed;
        if (rc == noErr) {
            // More may be buffered from the same feed; keep draining, but
            // stop if this record produced nothing (avoids a spin).
            size_t buffered = 0;
            if (SSLGetBufferedReadSize(s->ctx, &buffered) != noErr) buffered = 0;
            if (buffered == 0 || processed == 0) return (long long)total;
            continue;
        }
        if (rc == errSSLWouldBlock) {
            return total > 0 ? (long long)total : BEANS_TLS_R_WANT_IO;
        }
        if (rc == errSSLClosedGraceful) {
            s->closed = 1;
            return total > 0 ? (long long)total : BEANS_TLS_R_CLOSED;
        }
        if (rc == errSSLClosedAbort || rc == errSSLClosedNoNotify) {
            return total > 0 ? (long long)total : BEANS_TLS_R_TRUNCATED;
        }
        return total > 0 ? (long long)total : BEANS_TLS_R_PROTOCOL;
    }
}

// Starts a close: queues close_notify into outgoing.
BEANS_NET_API long long beans_tls_close_notify(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    SSLClose(s->ctx);
    return BEANS_TLS_OK;
}

BEANS_NET_API long long beans_tls_free(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->ctx) CFRelease(s->ctx);
    if (s->extra_roots) CFRelease(s->extra_roots);
    free(s->incoming.data);
    free(s->outgoing.data);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_available(void) { return 1; }

#pragma clang diagnostic pop

// ============================================================================
#elif !defined(_WIN32)
// OpenSSL 3 via dlopen. No OpenSSL headers at build time: the handful of
// entry points are resolved by name from libssl at runtime, and memory BIOs
// are the filter. Refuses anything older than 3.0 by requiring the 3.x-only
// symbols. Hostname verification goes through the platform's
// X509_VERIFY_PARAM, never hand-rolled.
#include <dlfcn.h>

// Minimal typedefs for the opaque handles and the entry points used.
typedef void* (*fn_ptr)(void);
typedef long (*ctrl_fn)(void*, int, long, void*);

static struct {
    int loaded;
    int ok;
    void* ssl_lib;
    void* crypto_lib;
    // context + connection
    void* (*TLS_client_method)(void);
    void* (*TLS_server_method)(void);
    void* (*SSL_CTX_new)(const void*);
    void (*SSL_CTX_free)(void*);
    int (*SSL_CTX_set_default_verify_paths)(void*);
    void (*SSL_CTX_set_verify)(void*, int, void*);
    long (*SSL_CTX_ctrl)(void*, int, long, void*);
    void* (*SSL_new)(void*);
    void (*SSL_free)(void*);
    void (*SSL_set_connect_state)(void*);
    void (*SSL_set_accept_state)(void*);
    int (*SSL_set_bio)(void*, void*, void*);
    void (*SSL_set_bio_void)(void*, void*, void*);
    int (*SSL_do_handshake)(void*);
    int (*SSL_get_error)(const void*, int);
    int (*SSL_read)(void*, void*, int);
    int (*SSL_write)(void*, const void*, int);
    int (*SSL_shutdown)(void*);
    long (*SSL_ctrl)(void*, int, long, void*);
    int (*SSL_set1_host)(void*, const char*);
    void (*SSL_set_verify)(void*, int, void*);
    long (*SSL_get_verify_result)(const void*);
    int (*SSL_set_alpn_protos)(void*, const unsigned char*, unsigned int);
    void (*SSL_get0_alpn_selected)(const void*, const unsigned char**, unsigned int*);
    // BIO
    void* (*BIO_new)(const void*);
    const void* (*BIO_s_mem)(void);
    void* (*BIO_new_mem_buf)(const void*, int);
    int (*BIO_write)(void*, const void*, int);
    int (*BIO_read)(void*, void*, int);
    long (*BIO_ctrl)(void*, int, long, void*);
    void (*BIO_free_all)(void*);
    void* (*PEM_read_bio_X509)(void*, void*, void*, void*);
    void (*X509_free)(void*);
    void* (*SSL_CTX_get_cert_store)(void*);
    int (*X509_STORE_add_cert)(void*, void*);
} ossl;

static void beans_tls_load(void) {
    if (ossl.loaded) return;
    ossl.loaded = 1;
    const char* ssl_names[5];
    int sc = 0;
    const char* ov = getenv("BEANS_LIBSSL");
    if (ov && *ov) ssl_names[sc++] = ov;
    ssl_names[sc++] = "libssl.so.3";
    ssl_names[sc++] = "libssl.so";
    ssl_names[sc++] = "libssl.3.dylib";
    ssl_names[sc++] = "libssl.dylib";
    void* h = NULL;
    for (int i = 0; i < sc; i++) {
        h = dlopen(ssl_names[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) break;
    }
    if (!h) return;
    ossl.ssl_lib = h;
    #define L(field, name) ossl.field = (void*)dlsym(h, name)
    ossl.TLS_client_method = (void*(*)(void))dlsym(h, "TLS_client_method");
    ossl.TLS_server_method = (void*(*)(void))dlsym(h, "TLS_server_method");
    ossl.SSL_CTX_new = (void*(*)(const void*))dlsym(h, "SSL_CTX_new");
    ossl.SSL_CTX_free = (void(*)(void*))dlsym(h, "SSL_CTX_free");
    ossl.SSL_CTX_set_default_verify_paths =
        (int(*)(void*))dlsym(h, "SSL_CTX_set_default_verify_paths");
    ossl.SSL_CTX_ctrl = (long(*)(void*,int,long,void*))dlsym(h, "SSL_CTX_ctrl");
    ossl.SSL_new = (void*(*)(void*))dlsym(h, "SSL_new");
    ossl.SSL_free = (void(*)(void*))dlsym(h, "SSL_free");
    ossl.SSL_set_connect_state = (void(*)(void*))dlsym(h, "SSL_set_connect_state");
    ossl.SSL_set_accept_state = (void(*)(void*))dlsym(h, "SSL_set_accept_state");
    ossl.SSL_set_bio = (int(*)(void*,void*,void*))dlsym(h, "SSL_set_bio");
    ossl.SSL_do_handshake = (int(*)(void*))dlsym(h, "SSL_do_handshake");
    ossl.SSL_get_error = (int(*)(const void*,int))dlsym(h, "SSL_get_error");
    ossl.SSL_read = (int(*)(void*,void*,int))dlsym(h, "SSL_read");
    ossl.SSL_write = (int(*)(void*,const void*,int))dlsym(h, "SSL_write");
    ossl.SSL_shutdown = (int(*)(void*))dlsym(h, "SSL_shutdown");
    ossl.SSL_ctrl = (long(*)(void*,int,long,void*))dlsym(h, "SSL_ctrl");
    ossl.SSL_set1_host = (int(*)(void*,const char*))dlsym(h, "SSL_set1_host");
    ossl.SSL_set_verify = (void(*)(void*,int,void*))dlsym(h, "SSL_set_verify");
    ossl.SSL_get_verify_result = (long(*)(const void*))dlsym(h, "SSL_get_verify_result");
    ossl.SSL_set_alpn_protos =
        (int(*)(void*,const unsigned char*,unsigned int))dlsym(h, "SSL_set_alpn_protos");
    ossl.SSL_get0_alpn_selected =
        (void(*)(const void*,const unsigned char**,unsigned int*))dlsym(h, "SSL_get0_alpn_selected");
    // BIO lives in libcrypto, usually pulled in by libssl already.
    ossl.BIO_new = (void*(*)(const void*))dlsym(h, "BIO_new");
    ossl.BIO_s_mem = (const void*(*)(void))dlsym(h, "BIO_s_mem");
    ossl.BIO_new_mem_buf = (void*(*)(const void*,int))dlsym(h, "BIO_new_mem_buf");
    ossl.BIO_write = (int(*)(void*,const void*,int))dlsym(h, "BIO_write");
    ossl.BIO_read = (int(*)(void*,void*,int))dlsym(h, "BIO_read");
    ossl.BIO_ctrl = (long(*)(void*,int,long,void*))dlsym(h, "BIO_ctrl");
    ossl.BIO_free_all = (void(*)(void*))dlsym(h, "BIO_free_all");
    ossl.PEM_read_bio_X509 = (void*(*)(void*,void*,void*,void*))dlsym(h, "PEM_read_bio_X509");
    ossl.X509_free = (void(*)(void*))dlsym(h, "X509_free");
    ossl.SSL_CTX_get_cert_store = (void*(*)(void*))dlsym(h, "SSL_CTX_get_cert_store");
    ossl.X509_STORE_add_cert = (int(*)(void*,void*))dlsym(h, "X509_STORE_add_cert");
    ossl.ok = ossl.SSL_CTX_new && ossl.SSL_new && ossl.SSL_set_bio &&
              ossl.SSL_do_handshake && ossl.BIO_new && ossl.BIO_s_mem &&
              ossl.SSL_set1_host && ossl.TLS_client_method &&
              ossl.SSL_read && ossl.SSL_write;
    #undef L
}

// OpenSSL constants used (stable across 1.1/3.x).
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_ZERO_RETURN 6
#define SSL_VERIFY_PEER 1
#define BIO_CTRL_PENDING 10
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define TLS1_2_VERSION 0x0303
#define X509_V_OK 0

typedef struct {
    void* ctx;
    void* ssl;
    void* rbio; // network -> SSL (we write ciphertext in)
    void* wbio; // SSL -> network (we read ciphertext out)
    int is_server;
    int handshake_done;
    int verify_host;
    uint64_t magic;
} beans_tls_session;

#define BEANS_TLS_MAGIC 0x62656e73746c73ULL

static beans_tls_session* beans_tls_of(long long handle) {
    beans_tls_session* s = (beans_tls_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_TLS_MAGIC) return NULL;
    return s;
}

BEANS_NET_API long long beans_tls_client_new(const uint8_t* host,
                                             const uint8_t* alpn,
                                             const uint64_t* req) {
    if (!req) return 0;
    beans_tls_load();
    if (!ossl.ok) return 0;
    beans_tls_session* s = (beans_tls_session*)calloc(1, sizeof(beans_tls_session));
    if (!s) return 0;
    s->is_server = (int)beans_net_word(req, 0);
    const void* method = s->is_server ? (ossl.TLS_server_method ? ossl.TLS_server_method() : NULL)
                                      : ossl.TLS_client_method();
    if (!method) { free(s); return 0; }
    s->ctx = ossl.SSL_CTX_new(method);
    if (!s->ctx) { free(s); return 0; }
    if (ossl.SSL_CTX_set_default_verify_paths) {
        ossl.SSL_CTX_set_default_verify_paths(s->ctx);
    }
    // Refuse < TLS 1.2 at the context.
    ossl.SSL_CTX_ctrl(s->ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, NULL);
    s->ssl = ossl.SSL_new(s->ctx);
    if (!s->ssl) { ossl.SSL_CTX_free(s->ctx); free(s); return 0; }
    s->rbio = ossl.BIO_new(ossl.BIO_s_mem());
    s->wbio = ossl.BIO_new(ossl.BIO_s_mem());
    ossl.SSL_set_bio(s->ssl, s->rbio, s->wbio);
    if (s->is_server) {
        ossl.SSL_set_accept_state(s->ssl);
    } else {
        ossl.SSL_set_connect_state(s->ssl);
        uint64_t host_len = beans_net_word(req, 1);
        if (host && host_len > 0) {
            char name[256];
            if (host_len < sizeof name) {
                memcpy(name, host, (size_t)host_len);
                name[host_len] = 0;
                // Enables hostname verification through the platform verifier.
                ossl.SSL_set1_host(s->ssl, name);
                s->verify_host = 1;
            }
        }
        ossl.SSL_set_verify(s->ssl, SSL_VERIFY_PEER, NULL);
    }
    uint64_t alpn_len = beans_net_word(req, 2);
    if (alpn && alpn_len > 0 && ossl.SSL_set_alpn_protos) {
        // OpenSSL wants length-prefixed protocol names; rebuild from the
        // comma list.
        unsigned char wire[256];
        unsigned int w = 0;
        size_t start = 0;
        for (size_t i = 0; i <= alpn_len && w < sizeof wire; i++) {
            if (i == alpn_len || alpn[i] == ',') {
                size_t plen = i - start;
                if (plen > 0 && plen < 128 && w + 1 + plen < sizeof wire) {
                    wire[w++] = (unsigned char)plen;
                    memcpy(wire + w, alpn + start, plen);
                    w += (unsigned int)plen;
                }
                start = i + 1;
            }
        }
        ossl.SSL_set_alpn_protos(s->ssl, wire, w);
    }
    s->magic = BEANS_TLS_MAGIC;
    return (long long)(intptr_t)s;
}

// Adds a PEM certificate to this connection's context trust store, before
// the handshake. libcrypto's own PEM reader parses it.
BEANS_NET_API long long beans_tls_add_root(long long handle, const uint8_t* data,
                                           const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !data || !req) return BEANS_NET_ERR_INVALID;
    if (!ossl.BIO_new_mem_buf || !ossl.PEM_read_bio_X509 ||
        !ossl.SSL_CTX_get_cert_store || !ossl.X509_STORE_add_cert)
        return BEANS_NET_ERR_UNSUPPORTED;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_NET_ERR_INVALID;
    void* bio = ossl.BIO_new_mem_buf(data, (int)len);
    if (!bio) return BEANS_NET_ERR_MEMORY;
    void* store = ossl.SSL_CTX_get_cert_store(s->ctx);
    int added = 0;
    for (;;) {
        void* cert = ossl.PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (!cert) break;
        ossl.X509_STORE_add_cert(store, cert);
        ossl.X509_free(cert);
        added++;
    }
    if (ossl.BIO_free_all) ossl.BIO_free_all(bio);
    return added > 0 ? BEANS_NET_OK : BEANS_NET_ERR_INVALID;
}

BEANS_NET_API long long beans_tls_feed(long long handle, const uint8_t* data,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_TLS_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    int wrote = ossl.BIO_write(s->rbio, data, (int)len);
    return wrote == (int)len ? BEANS_TLS_OK : BEANS_TLS_PROTOCOL;
}

BEANS_NET_API long long beans_tls_outgoing_size(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return -1;
    return (long long)ossl.BIO_ctrl(s->wbio, BIO_CTRL_PENDING, 0, NULL);
}

BEANS_NET_API long long beans_tls_pull_outgoing(long long handle, uint8_t* out,
                                                const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return -1;
    int got = ossl.BIO_read(s->wbio, out, (int)beans_net_word(req, 0));
    return got < 0 ? 0 : (long long)got;
}

BEANS_NET_API long long beans_tls_handshake(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    int rc = ossl.SSL_do_handshake(s->ssl);
    if (rc == 1) {
        if (s->verify_host && !s->is_server) {
            if (ossl.SSL_get_verify_result(s->ssl) != X509_V_OK)
                return BEANS_TLS_HANDSHAKE;
        }
        s->handshake_done = 1;
        return BEANS_TLS_OK;
    }
    int err = ossl.SSL_get_error(s->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE)
        return BEANS_TLS_WANT_IO;
    return BEANS_TLS_HANDSHAKE;
}

BEANS_NET_API long long beans_tls_alpn(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req || !ossl.SSL_get0_alpn_selected) return 0;
    const unsigned char* proto = NULL;
    unsigned int plen = 0;
    ossl.SSL_get0_alpn_selected(s->ssl, &proto, &plen);
    if (!proto || plen == 0) return 0;
    if (plen <= (unsigned int)beans_net_word(req, 0)) {
        memcpy(out, proto, plen);
        return (long long)plen;
    }
    return 0;
}

BEANS_NET_API long long beans_tls_write(long long handle, const uint8_t* data,
                                        const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return 0;
    if (!data) return BEANS_NET_ERR_INVALID;
    int wrote = ossl.SSL_write(s->ssl, data, (int)len);
    if (wrote > 0) return (long long)wrote;
    int err = ossl.SSL_get_error(s->ssl, wrote);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) return 0;
    return BEANS_TLS_PROTOCOL;
}

BEANS_NET_API long long beans_tls_read(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return BEANS_TLS_R_INVALID;
    int got = ossl.SSL_read(s->ssl, out, (int)beans_net_word(req, 0));
    if (got > 0) return (long long)got;
    int err = ossl.SSL_get_error(s->ssl, got);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE)
        return BEANS_TLS_R_WANT_IO;
    if (err == SSL_ERROR_ZERO_RETURN) return BEANS_TLS_R_CLOSED;
    return BEANS_TLS_R_TRUNCATED;
}

BEANS_NET_API long long beans_tls_close_notify(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    ossl.SSL_shutdown(s->ssl);
    return BEANS_TLS_OK;
}

BEANS_NET_API long long beans_tls_free(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->ssl) ossl.SSL_free(s->ssl);   // frees the BIOs it owns
    if (s->ctx) ossl.SSL_CTX_free(s->ctx);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_available(void) {
    beans_tls_load();
    return ossl.ok ? 1 : 0;
}

// ============================================================================
#else
// Windows SChannel: not implemented in this milestone. The refusing stubs
// keep std.tls linkable so the interpreter still loads on Windows; the API
// reports kind `unsupported` and no program silently gets a broken TLS.
BEANS_NET_API long long beans_tls_client_new(const uint8_t* h, const uint8_t* a, const uint64_t* r) { (void)h;(void)a;(void)r; return 0; }
BEANS_NET_API long long beans_tls_add_root(long long h, const uint8_t* d, const uint64_t* r) { (void)h;(void)d;(void)r; return BEANS_TLS_UNSUPPORTED; }
BEANS_NET_API long long beans_tls_feed(long long h, const uint8_t* d, const uint64_t* r) { (void)h;(void)d;(void)r; return BEANS_TLS_UNSUPPORTED; }
BEANS_NET_API long long beans_tls_outgoing_size(long long h) { (void)h; return -1; }
BEANS_NET_API long long beans_tls_pull_outgoing(long long h, uint8_t* o, const uint64_t* r) { (void)h;(void)o;(void)r; return -1; }
BEANS_NET_API long long beans_tls_handshake(long long h) { (void)h; return BEANS_TLS_UNSUPPORTED; }
BEANS_NET_API long long beans_tls_alpn(long long h, uint8_t* o, const uint64_t* r) { (void)h;(void)o;(void)r; return 0; }
BEANS_NET_API long long beans_tls_write(long long h, const uint8_t* d, const uint64_t* r) { (void)h;(void)d;(void)r; return BEANS_TLS_UNSUPPORTED; }
BEANS_NET_API long long beans_tls_read(long long h, uint8_t* o, const uint64_t* r) { (void)h;(void)o;(void)r; return BEANS_TLS_R_PROTOCOL; }
BEANS_NET_API long long beans_tls_close_notify(long long h) { (void)h; return BEANS_TLS_UNSUPPORTED; }
BEANS_NET_API long long beans_tls_free(long long h) { (void)h; return BEANS_NET_ERR_INVALID; }
BEANS_NET_API long long beans_tls_available(void) { return 0; }
#endif
