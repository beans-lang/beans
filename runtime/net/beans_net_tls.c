// TLS for std.tls — the platform's own stack, wrapping a socket as a filter.
//
// The connected-socket API is a byte pump: Beans owns the descriptor and
// feeds and drains TLS records. The macOS listener API is the one exception.
// Network.framework must own accepted connections to provide TLS 1.3 and
// server ALPN, so its read/write bridge waits for framework callbacks.
//
// Three backends behind one contract:
//   macOS      SecureTransport for accepted sockets; Network.framework for
//              listeners, server ALPN, and TLS 1.3
//   Linux/BSD  OpenSSL 3 via dlopen (libssl.so.3), memory BIOs
//   Windows    SChannel through SSPI, with the same in/out token pump
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
#include <stdio.h>

// These sit above the shared BEANS_NET_ERR_* codes on purpose. WANT_IO used
// to be 1 and CLOSED 2, which collide with BEANS_NET_ERR_INVALID and
// BEANS_NET_ERR_RANGE in the same return word -- a rejected handle then read
// back as "wants IO" and sent the caller round the handshake loop.
enum {
    BEANS_TLS_OK = 0,
    BEANS_TLS_HANDSHAKE = 110,   // handshake failed (cert, protocol, alert)
    BEANS_TLS_PROTOCOL = 111,    // record-layer error
    BEANS_TLS_TRUNCATED = 112,   // stream cut without close_notify
    BEANS_TLS_UNSUPPORTED = 113, // no backend on this platform
    BEANS_TLS_WANT_IO = 114,     // needs more input, or has output to flush
    BEANS_TLS_CLOSED = 115,      // peer sent close_notify
};

// The data paths — read and write — return a byte count (>= 0) and these
// NEGATIVE sentinels otherwise, so a one-byte transfer is never mistaken for
// a status. The status enum above is only for calls that carry no count;
// mixing the two is how a 111-byte write reads back as BEANS_TLS_PROTOCOL.
enum {
    BEANS_TLS_R_WANT_IO = -1,
    BEANS_TLS_R_CLOSED = -2,
    BEANS_TLS_R_TRUNCATED = -3,
    BEANS_TLS_R_PROTOCOL = -4,
    BEANS_TLS_R_INVALID = -5,
    BEANS_TLS_R_UNSUPPORTED = -6,
    BEANS_TLS_R_WANT_WRITE = -7,
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
    if (more > SIZE_MAX - b->len) return 0;
    size_t needed = b->len + more;
    if (needed <= b->cap) return 1;
    // Compact consumed prefix first.
    if (b->head > 0) {
        memmove(b->data, b->data + b->head, b->len - b->head);
        b->len -= b->head;
        b->head = 0;
        needed = b->len + more;
        if (needed <= b->cap) return 1;
    }
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

// Reports whether the bytes were taken. Dropping them silently would
// desynchronize the record layer -- TLS has no way to resend what the
// transport claims to have absorbed.
static int beans_tls_buf_push(beans_tls_buf* b, const uint8_t* src, size_t n) {
    if (!beans_tls_buf_reserve(b, n)) return 0;
    if (n) memcpy(b->data + b->len, src, n);
    b->len += n;
    return 1;
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
#include <Network/Network.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

typedef struct beans_nw_connection beans_nw_connection;

typedef struct beans_tls_identity_entry {
    char name[256];
    CFArrayRef chain; // identity first, then intermediate certificates
    sec_identity_t nw_identity; // the same identity for Network.framework
    SecKeychainRef keychain; // ephemeral, only for this identity
    char keychain_path[96];
    struct beans_tls_identity_entry* next;
} beans_tls_identity_entry;

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
    CFArrayRef alpn_config; // server preference order, retained
    beans_tls_identity_entry* identities;
    beans_tls_identity_entry* default_identity;
    nw_listener_t nw_listener;
    dispatch_queue_t nw_queue;
    pthread_mutex_t nw_mutex;
    pthread_cond_t nw_changed;
    beans_nw_connection* nw_all;
    beans_nw_connection* nw_head;
    beans_nw_connection* nw_tail;
    int nw_sync_ready;
    int nw_state;
    int nw_closing;
    atomic_int nw_refs;
    uint64_t magic;
} beans_tls_session;

struct beans_nw_connection {
    nw_connection_t connection;
    dispatch_queue_t queue;
    beans_tls_session* owner;
    char alpn[256];
    uint64_t magic;
    beans_nw_connection* all_next;
    beans_nw_connection* ready_next;
};

#define BEANS_TLS_MAGIC 0x62656e73746c73ULL
#define BEANS_NW_TLS_MAGIC 0x62656e736e77746cULL

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
    if (!beans_tls_buf_push(&s->outgoing, (const uint8_t*)data, *len)) {
        // Tell SecureTransport nothing went out, so it retries rather than
        // believing records it never sent are on the wire.
        *len = 0;
        return errSSLWouldBlock;
    }
    return noErr;
}

// The certificate and key bytes travel as real pointer arguments, never as
// integers smuggled through `req` -- req carries lengths and flags only.
// req: [0] is_server, [1] host byte length, [2] alpn byte length.
// Returns a handle, or 0 if the session could not be created.
BEANS_NET_API long long beans_tls_client_new(const uint8_t* host,
                                             const uint8_t* alpn,
                                             const uint64_t* req) {
    if (!req) return 0;
    uint64_t role = beans_net_word(req, 0);
    uint64_t host_len = beans_net_word(req, 1);
    uint64_t alpn_len = beans_net_word(req, 2);
    if (role > 1 || host_len > SIZE_MAX || alpn_len > SIZE_MAX ||
        (!role && (!host || host_len == 0)) ||
        (host_len > 0 && !host) || (alpn_len > 0 && !alpn)) return 0;
    beans_tls_session* s = (beans_tls_session*)calloc(1, sizeof(beans_tls_session));
    if (!s) return 0;
    atomic_init(&s->nw_refs, 1);
    s->is_server = (int)role;
    s->ctx = SSLCreateContext(NULL, s->is_server ? kSSLServerSide : kSSLClientSide,
                              kSSLStreamType);
    if (!s->ctx) { free(s); return 0; }
    if (SSLSetIOFuncs(s->ctx, beans_tls_read_cb, beans_tls_write_cb) != noErr ||
        SSLSetConnection(s->ctx, s) != noErr ||
        SSLSetProtocolVersionMin(s->ctx, kTLSProtocol12) != noErr) goto fail;
    if (!s->is_server) {
        // A name that does not fit must fail the session, never skip the
        // check: silently dropping SNI here would leave a verified chain
        // with no hostname binding at all.
        if (host_len >= sizeof s->host) goto fail;
        if (SSLSetPeerDomainName(s->ctx, (const char*)host,
                                 (size_t)host_len) != noErr) goto fail;
        memcpy(s->host, host, (size_t)host_len);
        s->host[host_len] = 0;
        // Break out of the handshake at server-auth so trust is evaluated
        // here — with the caller's extra roots plus the system store, and
        // the hostname policy — rather than by SecureTransport's default
        // system-only evaluation. This is what lets a private CA or a
        // pinned root be trusted without ever hand-rolling chain building.
        if (SSLSetSessionOption(s->ctx,
                kSSLSessionOptionBreakOnServerAuth, true) != noErr) goto fail;
    } else {
        // Pause after ClientHello so an SNI-specific identity can be chosen
        // before SecureTransport constructs the server flight.
        if (SSLSetSessionOption(s->ctx,
                kSSLSessionOptionBreakOnClientHello, true) != noErr) goto fail;
    }
    if (alpn_len > 0) {
        // Split comma-separated protocols into a CFArray of CFStrings.
        CFMutableArrayRef protos =
            CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (!protos) goto fail;
        size_t start = 0;
        int valid = 1;
        for (size_t i = 0; i <= alpn_len; i++) {
            if (i == alpn_len || alpn[i] == ',') {
                size_t plen = i - start;
                if (plen > 0 && plen <= 255 && plen <= (size_t)LONG_MAX) {
                    CFStringRef proto = CFStringCreateWithBytes(
                        NULL, alpn + start, (CFIndex)plen,
                        kCFStringEncodingASCII, false);
                    if (proto) {
                        CFArrayAppendValue(protos, proto);
                        CFRelease(proto);
                    } else valid = 0;
                } else valid = 0;
                start = i + 1;
            }
        }
        OSStatus alpn_status = valid
            ? SSLSetALPNProtocols(s->ctx, protos) : errSecParam;
        if (valid && s->is_server) s->alpn_config = CFRetain(protos);
        CFRelease(protos);
        if (alpn_status != noErr) goto fail;
    }
    s->magic = BEANS_TLS_MAGIC;
    return (long long)(intptr_t)s;
fail:
    if (s->ctx) CFRelease(s->ctx);
    if (s->alpn_config) CFRelease(s->alpn_config);
    free(s);
    return 0;
}

static CFStringRef beans_tls_cf_string(const uint8_t* bytes, size_t len) {
    if (len > (size_t)LONG_MAX) return NULL;
    return CFStringCreateWithBytes(NULL, bytes, (CFIndex)len,
                                   kCFStringEncodingUTF8, false);
}

static SecKeychainRef beans_tls_temp_keychain(char path[96]) {
    char pattern[] = "/tmp/beans-tls-identity.XXXXXX";
    int fd = mkstemp(pattern);
    if (fd < 0) return NULL;
    close(fd);
    unlink(pattern);
    const char secret[] = "beans ephemeral identity";
    SecKeychainRef keychain = NULL;
    if (SecKeychainCreate(pattern, (UInt32)(sizeof(secret) - 1), secret,
                          false, NULL, &keychain) != errSecSuccess) {
        unlink(pattern);
        return NULL;
    }
    snprintf(path, 96, "%s", pattern);
    return keychain;
}

static void beans_tls_drop_keychain(SecKeychainRef keychain,
                                    const char* path) {
    if (keychain) {
        (void)SecKeychainDelete(keychain);
        CFRelease(keychain);
    }
    if (path && *path) unlink(path);
}

static const uint8_t* beans_tls_find(const uint8_t* hay, size_t n,
                                     const char* needle);

static CFArrayRef beans_tls_pem_identity(const uint8_t* cert, size_t cert_len,
                                         const uint8_t* key, size_t key_len,
                                         const uint8_t* password,
                                         size_t password_len,
                                         SecKeychainRef* kept_keychain,
                                         char kept_path[96]) {
    SecKeychainRef keychain = beans_tls_temp_keychain(kept_path);
    if (!keychain) return NULL;
    CFDataRef cert_data = CFDataCreate(NULL, cert, (CFIndex)cert_len);
    CFDataRef key_data = CFDataCreate(NULL, key, (CFIndex)key_len);
    if (!cert_data || !key_data) goto fail;
    SecExternalFormat cert_format = kSecFormatUnknown;
    SecExternalItemType cert_type = kSecItemTypeCertificate;
    CFArrayRef certs = NULL;
    OSStatus cert_status = SecItemImport(
        cert_data, NULL, &cert_format, &cert_type, 0, NULL, keychain, &certs);
    CFRelease(cert_data);
    cert_data = NULL;
    if (cert_status != errSecSuccess || !certs || CFArrayGetCount(certs) == 0) {
        if (certs) CFRelease(certs);
        goto fail;
    }

    CFStringRef pass = password_len
        ? beans_tls_cf_string(password, password_len) : NULL;
    SecItemImportExportKeyParameters params;
    memset(&params, 0, sizeof(params));
    params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    params.flags = kSecKeyNoAccessControl;
    params.passphrase = pass;
    SecExternalFormat key_format = kSecFormatUnknown;
    SecExternalItemType key_type = kSecItemTypePrivateKey;
    CFArrayRef keys = NULL;
    OSStatus key_status = SecItemImport(
        key_data, NULL, &key_format, &key_type, 0, &params,
        keychain, &keys);
    if (pass) CFRelease(pass);
    CFRelease(key_data);
    key_data = NULL;
    if (key_status != errSecSuccess || !keys || CFArrayGetCount(keys) == 0) {
        CFRelease(certs);
        if (keys) CFRelease(keys);
        goto fail;
    }

    SecCertificateRef leaf = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(certs); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(certs, i);
        if (CFGetTypeID(item) == SecCertificateGetTypeID()) {
            leaf = (SecCertificateRef)item;
            break;
        }
    }
    SecIdentityRef identity = NULL;
    if (leaf) (void)SecIdentityCreateWithCertificate(
        keychain, leaf, &identity);
    CFMutableArrayRef chain = identity
        ? CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks) : NULL;
    if (chain) {
        CFArrayAppendValue(chain, identity);
        for (CFIndex i = 0; i < CFArrayGetCount(certs); i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(certs, i);
            if (CFGetTypeID(item) == SecCertificateGetTypeID() && item != leaf)
                CFArrayAppendValue(chain, item);
        }
    }
    if (identity) CFRelease(identity);
    CFRelease(certs);
    CFRelease(keys);
    if (!chain) goto fail;
    *kept_keychain = keychain;
    return chain;
fail:
    if (cert_data) CFRelease(cert_data);
    if (key_data) CFRelease(key_data);
    beans_tls_drop_keychain(keychain, kept_path);
    kept_path[0] = 0;
    return NULL;
}

static CFArrayRef beans_tls_pkcs12_identity(const uint8_t* data, size_t len,
                                            const uint8_t* password,
                                            size_t password_len,
                                            SecKeychainRef* kept_keychain,
                                            char kept_path[96]) {
    SecKeychainRef keychain = beans_tls_temp_keychain(kept_path);
    if (!keychain) return NULL;
    CFDataRef blob = CFDataCreate(NULL, data, (CFIndex)len);
    CFStringRef pass = beans_tls_cf_string(password, password_len);
    if (!blob || !pass) {
        if (blob) CFRelease(blob);
        if (pass) CFRelease(pass);
        beans_tls_drop_keychain(keychain, kept_path);
        kept_path[0] = 0;
        return NULL;
    }
    const void* keys[] = {
        kSecImportExportPassphrase, kSecImportExportKeychain
    };
    const void* values[] = { pass, keychain };
    CFDictionaryRef options = CFDictionaryCreate(
        NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFArrayRef items = NULL;
    OSStatus status = options
        ? SecPKCS12Import(blob, options, &items) : errSecAllocate;
    if (options) CFRelease(options);
    CFRelease(pass);
    CFRelease(blob);
    if (status != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        if (items) CFRelease(items);
        beans_tls_drop_keychain(keychain, kept_path);
        kept_path[0] = 0;
        return NULL;
    }
    CFDictionaryRef first = (CFDictionaryRef)CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef identity = (SecIdentityRef)CFDictionaryGetValue(
        first, kSecImportItemIdentity);
    CFArrayRef certificates = (CFArrayRef)CFDictionaryGetValue(
        first, kSecImportItemCertChain);
    CFMutableArrayRef chain = identity
        ? CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks) : NULL;
    if (chain) {
        CFArrayAppendValue(chain, identity);
        if (certificates) {
            for (CFIndex i = 1; i < CFArrayGetCount(certificates); i++)
                CFArrayAppendValue(
                    chain, CFArrayGetValueAtIndex(certificates, i));
        }
    }
    CFRelease(items);
    if (!chain) {
        beans_tls_drop_keychain(keychain, kept_path);
        kept_path[0] = 0;
        return NULL;
    }
    *kept_keychain = keychain;
    return chain;
}

static sec_identity_t beans_tls_network_identity(CFArrayRef chain) {
    if (!chain || CFArrayGetCount(chain) == 0) return NULL;
    SecIdentityRef identity =
        (SecIdentityRef)CFArrayGetValueAtIndex(chain, 0);
    SecCertificateRef leaf = NULL;
    if (!identity || SecIdentityCopyCertificate(identity, &leaf) != errSecSuccess ||
        !leaf) return NULL;
    CFMutableArrayRef certificates =
        CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (!certificates) { CFRelease(leaf); return NULL; }
    CFArrayAppendValue(certificates, leaf);
    CFRelease(leaf);
    for (CFIndex i = 1; i < CFArrayGetCount(chain); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(chain, i);
        if (CFGetTypeID(item) == SecCertificateGetTypeID())
            CFArrayAppendValue(certificates, item);
    }
    sec_identity_t result =
        sec_identity_create_with_certificates(identity, certificates);
    CFRelease(certificates);
    return result;
}

// Adds one server identity. blob is [name][certificate/p12][private key]
// [password]; req is [format, name_len, cert_len, key_len, password_len].
BEANS_NET_API long long beans_tls_add_identity(long long handle,
                                               const uint8_t* blob,
                                               const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->is_server || !blob || !req || s->handshake_done)
        return BEANS_NET_ERR_INVALID;
    uint64_t format = beans_net_word(req, 0);
    uint64_t name_len = beans_net_word(req, 1);
    uint64_t cert_len = beans_net_word(req, 2);
    uint64_t key_len = beans_net_word(req, 3);
    uint64_t password_len = beans_net_word(req, 4);
    if (format > 1 || name_len >= 256 || cert_len == 0 ||
        (format == 0 && key_len == 0) ||
        name_len > SIZE_MAX || cert_len > SIZE_MAX || key_len > SIZE_MAX ||
        password_len > SIZE_MAX || cert_len > LONG_MAX || key_len > LONG_MAX ||
        password_len > LONG_MAX) return BEANS_NET_ERR_INVALID;
    size_t total = (size_t)name_len;
    if ((size_t)cert_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    total += (size_t)cert_len;
    if ((size_t)key_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    total += (size_t)key_len;
    if ((size_t)password_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    for (size_t i = 0; i < (size_t)name_len; i++)
        if (blob[i] == 0) return BEANS_NET_ERR_INVALID;
    const uint8_t* cert = blob + name_len;
    const uint8_t* key = cert + cert_len;
    const uint8_t* password = key + key_len;
    SecKeychainRef keychain = NULL;
    char keychain_path[96] = {0};
    CFArrayRef chain = format == 0
        ? beans_tls_pem_identity(cert, (size_t)cert_len, key, (size_t)key_len,
                                 password, (size_t)password_len,
                                 &keychain, keychain_path)
        : beans_tls_pkcs12_identity(cert, (size_t)cert_len, password,
                                    (size_t)password_len,
                                    &keychain, keychain_path);
    if (!chain) return BEANS_NET_ERR_INVALID;
    beans_tls_identity_entry* entry =
        (beans_tls_identity_entry*)calloc(1, sizeof(*entry));
    if (!entry) {
        CFRelease(chain);
        beans_tls_drop_keychain(keychain, keychain_path);
        return BEANS_NET_ERR_MEMORY;
    }
    memcpy(entry->name, blob, (size_t)name_len);
    entry->name[name_len] = 0;
    entry->chain = chain;
    entry->nw_identity = beans_tls_network_identity(chain);
    if (!entry->nw_identity) {
        CFRelease(chain);
        beans_tls_drop_keychain(keychain, keychain_path);
        free(entry);
        return BEANS_NET_ERR_INVALID;
    }
    entry->keychain = keychain;
    snprintf(entry->keychain_path, sizeof(entry->keychain_path), "%s",
             keychain_path);
    for (beans_tls_identity_entry* at = s->identities; at; at = at->next) {
        if (strcasecmp(at->name, entry->name) == 0) {
            sec_release(entry->nw_identity);
            CFRelease(chain);
            beans_tls_drop_keychain(keychain, keychain_path);
            free(entry);
            return BEANS_NET_ERR_INVALID;
        }
    }
    entry->next = s->identities;
    s->identities = entry;
    if (name_len == 0) {
        s->default_identity = entry;
        if (SSLSetCertificate(s->ctx, entry->chain) != noErr)
            return BEANS_TLS_PROTOCOL;
    }
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_feed(long long handle, const uint8_t* data,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_TLS_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    if (len > SIZE_MAX) return BEANS_NET_ERR_RANGE;
    // Reporting OK after dropping ciphertext would lose it for good -- Beans
    // has already consumed those bytes from the socket.
    if (!beans_tls_buf_push(&s->incoming, data, (size_t)len)) {
        return BEANS_TLS_PROTOCOL;
    }
    return BEANS_TLS_OK;
}

BEANS_NET_API long long beans_tls_pull_outgoing(long long handle, uint8_t* out,
                                                const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap > SIZE_MAX) cap = SIZE_MAX;
    return (long long)beans_tls_buf_take(&s->outgoing, out, (size_t)cap);
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
    if (!s->host[0]) { CFRelease(trust); return 0; }
    CFStringRef host = CFStringCreateWithCString(NULL, s->host,
                                                 kCFStringEncodingUTF8);
    if (!host) { CFRelease(trust); return 0; }
    SecPolicyRef policy = SecPolicyCreateSSL(true, host);
    CFRelease(host);
    if (!policy) { CFRelease(trust); return 0; }
    OSStatus policy_status = SecTrustSetPolicies(trust, policy);
    CFRelease(policy);
    if (policy_status != errSecSuccess) { CFRelease(trust); return 0; }
    if (s->extra_roots && CFArrayGetCount(s->extra_roots) > 0) {
        if (SecTrustSetAnchorCertificates(trust, s->extra_roots) != errSecSuccess ||
            SecTrustSetAnchorCertificatesOnly(trust, false) != errSecSuccess) {
            CFRelease(trust);
            return 0;
        }
        // false: the caller's roots are ADDED to the system store, not a
        // replacement, so a normal public chain still verifies.
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
        if (rc == errSSLClientHelloReceived && s->is_server) {
            // On the server SecureTransport exposes the peer's ALPN list at
            // the ClientHello break. Select one protocol in server order and
            // set that single value before continuing the handshake.
            if (s->alpn_config) {
                CFArrayRef peer_protocols = NULL;
                if (SSLCopyALPNProtocols(
                        s->ctx, &peer_protocols) == noErr && peer_protocols) {
                    CFStringRef choice = NULL;
                    for (CFIndex i = 0;
                         i < CFArrayGetCount(s->alpn_config) && !choice; i++) {
                        CFStringRef wanted = (CFStringRef)CFArrayGetValueAtIndex(
                            s->alpn_config, i);
                        for (CFIndex j = 0;
                             j < CFArrayGetCount(peer_protocols); j++) {
                            CFStringRef offered =
                                (CFStringRef)CFArrayGetValueAtIndex(
                                    peer_protocols, j);
                            if (CFStringCompare(
                                    wanted, offered, 0) == kCFCompareEqualTo) {
                                choice = wanted;
                                break;
                            }
                        }
                    }
                    if (choice) {
                        const void* value = choice;
                        CFArrayRef selected = CFArrayCreate(
                            NULL, &value, 1, &kCFTypeArrayCallBacks);
                        if (!selected || SSLSetALPNProtocols(
                                s->ctx, selected) != noErr) {
                            if (selected) CFRelease(selected);
                            CFRelease(peer_protocols);
                            return BEANS_TLS_HANDSHAKE;
                        }
                        CFRelease(selected);
                    }
                    CFRelease(peer_protocols);
                }
            }
            beans_tls_identity_entry* selected = s->default_identity;
            size_t requested_len = 0;
            if (SSLCopyRequestedPeerNameLength(
                    s->ctx, &requested_len) == noErr && requested_len > 0 &&
                requested_len < 256) {
                char requested[256];
                size_t copied = requested_len;
                if (SSLCopyRequestedPeerName(
                        s->ctx, requested, &copied) == noErr && copied < 256) {
                    requested[copied] = 0;
                    for (beans_tls_identity_entry* at = s->identities;
                         at; at = at->next) {
                        if (at->name[0] &&
                            strcasecmp(at->name, requested) == 0) {
                            selected = at;
                            break;
                        }
                    }
                }
            }
            if (!selected || SSLSetCertificate(
                    s->ctx, selected->chain) != noErr)
                return BEANS_TLS_HANDSHAKE;
            continue;
        }
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

// Finds `needle` inside [hay, hay+n). Beans Bytes carry an explicit length
// and are never NUL-terminated, so every scan over them must be bounded --
// strstr here would run off the end of the allocation.
static const uint8_t* beans_tls_find(const uint8_t* hay, size_t n,
                                     const char* needle) {
    size_t m = strlen(needle);
    if (m == 0 || n < m) return NULL;
    for (size_t i = 0; i + m <= n; i++) {
        if (memcmp(hay + i, needle, m) == 0) return hay + i;
    }
    return NULL;
}

// Appends one DER blob to the session's extra trust anchors.
static long long beans_tls_push_der(beans_tls_session* s,
                                    const uint8_t* der, size_t n) {
    if (n > (size_t)LONG_MAX) return BEANS_NET_ERR_RANGE;
    CFDataRef blob = CFDataCreate(NULL, der, (CFIndex)n);
    if (!blob) return BEANS_NET_ERR_MEMORY;
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, blob);
    CFRelease(blob);
    if (!cert) return BEANS_NET_ERR_INVALID;
    if (!s->extra_roots) {
        s->extra_roots = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (!s->extra_roots) { CFRelease(cert); return BEANS_NET_ERR_MEMORY; }
    }
    CFArrayAppendValue(s->extra_roots, cert);
    CFRelease(cert);
    return BEANS_NET_OK;
}

// Adds a PEM or DER certificate as an extra trust anchor, before the
// handshake. Used for private CAs and pinning. A PEM bundle may hold several
// certificates; every one of them is added, matching the OpenSSL backend.
BEANS_NET_API long long beans_tls_add_root(long long handle, const uint8_t* data,
                                           const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !data || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0 || len > (uint64_t)SIZE_MAX) return BEANS_NET_ERR_INVALID;
    size_t n = (size_t)len;
    // DER is passed through; PEM gets its armor stripped, because
    // SecCertificateCreateWithData only speaks DER.
    if (!(n > 10 && memcmp(data, "-----BEGIN", 10) == 0)) {
        return beans_tls_push_der(s, data, n);
    }
    const uint8_t* cursor = data;
    const uint8_t* limit = data + n;
    long long added = 0;
    while (cursor < limit) {
        const uint8_t* begin =
            beans_tls_find(cursor, (size_t)(limit - cursor), "-----BEGIN");
        if (!begin) break;
        // The base64 body starts after the BEGIN line's newline.
        const uint8_t* body =
            beans_tls_find(begin, (size_t)(limit - begin), "\n");
        if (!body) break;
        body++;
        const uint8_t* end =
            beans_tls_find(body, (size_t)(limit - body), "-----END");
        // A bundle truncated mid-certificate is rejected outright rather than
        // decoded to whatever happens to follow it.
        if (!end) break;
        unsigned char* out = (unsigned char*)malloc((size_t)(end - body) + 1);
        if (!out) return BEANS_NET_ERR_MEMORY;
        size_t olen = 0;
        int bits = 0, acc = 0;
        size_t symbols = 0, padding = 0;
        int padded = 0, bad = 0;
        for (const uint8_t* p = body; p < end; p++) {
            int c = (int)*p;
            int v = -1;
            if (c >= 'A' && c <= 'Z') v = c - 'A';
            else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
            else if (c >= '0' && c <= '9') v = c - '0' + 52;
            else if (c == '+') v = 62;
            else if (c == '/') v = 63;
            else if (c == '=') {
                padded = 1;
                padding++;
                continue;
            } else if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                continue;
            } else {
                bad = 1;
                break;
            }
            if (padded) { bad = 1; break; }
            acc = (acc << 6) | v;
            symbols++;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out[olen++] = (unsigned char)(acc >> bits);
                // Retain only the unconsumed low bits. Without this mask the
                // signed accumulator eventually overflows on any real cert.
                acc &= bits == 0 ? 0 : (1 << bits) - 1;
            }
        }
        if (padding > 2 || (symbols + padding) % 4 != 0 ||
            (padding == 0 && symbols % 4 != 0) ||
            (padding == 1 && symbols % 4 != 3) ||
            (padding == 2 && symbols % 4 != 2) || acc != 0)
            bad = 1;
        long long rc = !bad && olen > 0
            ? beans_tls_push_der(s, out, olen) : BEANS_NET_ERR_INVALID;
        free(out);
        if (rc != BEANS_NET_OK) return rc;
        added++;
        cursor = (size_t)(limit - end) >= 8 ? end + 8 : limit;
    }
    if (added == 0) return BEANS_NET_ERR_INVALID;
    return BEANS_NET_OK;
}

// Returns the negotiated ALPN protocol into `out`; length as the return,
// 0 if none, negative on error.
BEANS_NET_API long long beans_tls_alpn(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap > SIZE_MAX) cap = SIZE_MAX;
    CFArrayRef protos = NULL;
    if (SSLCopyALPNProtocols(s->ctx, &protos) != noErr || !protos) return 0;
    long long written = 0;
    if (CFArrayGetCount(protos) > 0) {
        CFStringRef first = (CFStringRef)CFArrayGetValueAtIndex(protos, 0);
        char buf[64];
        if (CFStringGetCString(first, buf, sizeof buf, kCFStringEncodingASCII)) {
            size_t n = strlen(buf);
            if (n <= (size_t)cap) {
                memcpy(out, buf, n);
                written = (long long)n;
            }
        }
    }
    CFRelease(protos);
    return written;
}

// Writes app data. Return: bytes accepted (>=0), or a negative sentinel --
// never a status code, or a 111-byte write would read back as an error.
BEANS_NET_API long long beans_tls_write(long long handle, const uint8_t* data,
                                        const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_TLS_R_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return 0;
    if (!data) return BEANS_TLS_R_INVALID;
    if (len > SIZE_MAX) return BEANS_TLS_R_INVALID;
    size_t processed = 0;
    OSStatus rc = SSLWrite(s->ctx, data, (size_t)len, &processed);
    if (rc == noErr || rc == errSSLWouldBlock) return (long long)processed;
    return BEANS_TLS_R_PROTOCOL;
}

// Reads decrypted app data into `out`. Return: bytes read (>=0),
// BEANS_TLS_WANT_IO when nothing is ready yet, BEANS_TLS_CLOSED on a clean
// close_notify, BEANS_TLS_TRUNCATED on an abrupt end.
BEANS_NET_API long long beans_tls_read(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return BEANS_TLS_R_INVALID;
    uint64_t requested = beans_net_word(req, 0);
    if (requested > SIZE_MAX) return BEANS_TLS_R_INVALID;
    size_t want = (size_t)requested;
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
static beans_nw_connection* beans_tls_nw_of(long long handle) {
    beans_nw_connection* c = (beans_nw_connection*)(intptr_t)handle;
    if (!c || c->magic != BEANS_NW_TLS_MAGIC || !c->connection) return NULL;
    return c;
}

static void beans_tls_nw_drop(beans_nw_connection* c, int cancel) {
    if (!c) return;
    if (c->connection) {
        nw_connection_set_state_changed_handler(c->connection, NULL);
        if (cancel) nw_connection_cancel(c->connection);
        nw_release(c->connection);
    }
    if (c->queue) dispatch_release(c->queue);
    c->magic = 0;
    free(c);
}

static void beans_tls_nw_remove_locked(beans_tls_session* s,
                                       beans_nw_connection* c) {
    beans_nw_connection** at = &s->nw_all;
    while (*at) {
        if (*at == c) {
            *at = c->all_next;
            c->all_next = NULL;
            return;
        }
        at = &(*at)->all_next;
    }
}

static void beans_tls_nw_capture_alpn(beans_nw_connection* c) {
    nw_protocol_definition_t definition = nw_protocol_copy_tls_definition();
    if (!definition) return;
    nw_protocol_metadata_t metadata =
        nw_connection_copy_protocol_metadata(c->connection, definition);
    nw_release(definition);
    if (!metadata) return;
    sec_protocol_metadata_t sec = nw_tls_copy_sec_protocol_metadata(metadata);
    nw_release(metadata);
    if (!sec) return;
    const char* protocol = sec_protocol_metadata_get_negotiated_protocol(sec);
    if (protocol) snprintf(c->alpn, sizeof(c->alpn), "%s", protocol);
    sec_release(sec);
}

static int beans_tls_deadline(uint64_t timeout_ms, struct timespec* limit) {
    if (!limit || timeout_ms == 0) return 0;
    if (clock_gettime(CLOCK_REALTIME, limit) != 0) return -1;
    uint64_t seconds = timeout_ms / 1000;
    uint64_t nanos = (timeout_ms % 1000) * 1000000ULL;
    if (limit->tv_sec < 0 ||
        seconds > (uint64_t)LONG_MAX - (uint64_t)limit->tv_sec) return -1;
    limit->tv_sec += (time_t)seconds;
    long total_nanos = limit->tv_nsec + (long)nanos;
    if (total_nanos >= 1000000000L) {
        if (limit->tv_sec == LONG_MAX) return -1;
        limit->tv_sec += 1;
        total_nanos -= 1000000000L;
    }
    limit->tv_nsec = total_nanos;
    return 0;
}

static int beans_tls_cond_wait_until(pthread_cond_t* changed,
                                     pthread_mutex_t* mutex,
                                     const struct timespec* limit) {
    return limit ? pthread_cond_timedwait(changed, mutex, limit)
                 : pthread_cond_wait(changed, mutex);
}

// Starts a Network.framework TLS listener from a server session whose
// identities were loaded through beans_tls_add_identity. req is
// [host_len, port, start_timeout_ms].
BEANS_NET_API long long beans_tls_listener_start(long long handle,
                                                 const uint8_t* host,
                                                 const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->is_server || !s->default_identity || !host || !req ||
        s->nw_listener) return BEANS_NET_ERR_INVALID;
    uint64_t host_len = beans_net_word(req, 0);
    uint64_t port = beans_net_word(req, 1);
    uint64_t timeout_ms = beans_net_word(req, 2);
    if (host_len == 0 || host_len >= 256 || port > 65535)
        return BEANS_NET_ERR_INVALID;
    char host_text[256];
    memcpy(host_text, host, (size_t)host_len);
    host_text[host_len] = 0;
    char port_text[8];
    snprintf(port_text, sizeof(port_text), "%llu",
             (unsigned long long)port);

    if (pthread_mutex_init(&s->nw_mutex, NULL) != 0)
        return BEANS_NET_ERR_MEMORY;
    if (pthread_cond_init(&s->nw_changed, NULL) != 0) {
        pthread_mutex_destroy(&s->nw_mutex);
        return BEANS_NET_ERR_MEMORY;
    }
    s->nw_sync_ready = 1;
    s->nw_queue = dispatch_queue_create(
        "org.beans.tls.listener", DISPATCH_QUEUE_SERIAL);
    if (!s->nw_queue) return BEANS_NET_ERR_MEMORY;

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(
        ^(nw_protocol_options_t options) {
            sec_protocol_options_t sec =
                nw_tls_copy_sec_protocol_options(options);
            if (!sec) return;
            sec_protocol_options_set_min_tls_protocol_version(
                sec, tls_protocol_version_TLSv12);
            // Do not set a local identity here. Network.framework asks for
            // one through the challenge block after it has parsed SNI. If a
            // default is installed up front, the challenge never runs and a
            // named certificate can never be selected.
            for (CFIndex i = 0; s->alpn_config &&
                 i < CFArrayGetCount(s->alpn_config); i++) {
                CFStringRef value =
                    (CFStringRef)CFArrayGetValueAtIndex(s->alpn_config, i);
                char protocol[256];
                if (CFStringGetCString(value, protocol, sizeof(protocol),
                                       kCFStringEncodingASCII))
                    sec_protocol_options_add_tls_application_protocol(
                        sec, protocol);
            }
            sec_protocol_options_set_challenge_block(
                sec,
                ^(sec_protocol_metadata_t metadata,
                  sec_protocol_challenge_complete_t complete) {
                    beans_tls_identity_entry* selected = s->default_identity;
                    const char* requested =
                        sec_protocol_metadata_get_server_name(metadata);
                    if (requested && *requested) {
                        for (beans_tls_identity_entry* at = s->identities;
                             at; at = at->next) {
                            if (at->name[0] &&
                                strcasecmp(at->name, requested) == 0) {
                                selected = at;
                                break;
                            }
                        }
                    }
                    complete(selected ? selected->nw_identity : NULL);
                }, s->nw_queue);
            sec_release(sec);
        }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    if (!parameters) return BEANS_NET_ERR_MEMORY;
    nw_endpoint_t endpoint = nw_endpoint_create_host(host_text, port_text);
    if (!endpoint) { nw_release(parameters); return BEANS_NET_ERR_INVALID; }
    nw_parameters_set_local_endpoint(parameters, endpoint);
    nw_release(endpoint);
    s->nw_listener = nw_listener_create(parameters);
    nw_release(parameters);
    if (!s->nw_listener) return BEANS_NET_ERR_INVALID;

    nw_listener_set_queue(s->nw_listener, s->nw_queue);
    nw_listener_set_state_changed_handler(
        s->nw_listener, ^(nw_listener_state_t state, nw_error_t error) {
            (void)error;
            pthread_mutex_lock(&s->nw_mutex);
            if (state == nw_listener_state_ready) s->nw_state = 1;
            else if (state == nw_listener_state_failed ||
                     state == nw_listener_state_cancelled) s->nw_state = -1;
            pthread_cond_broadcast(&s->nw_changed);
            pthread_mutex_unlock(&s->nw_mutex);
        });
    nw_listener_set_new_connection_handler(
        s->nw_listener, ^(nw_connection_t connection) {
            beans_nw_connection* c =
                (beans_nw_connection*)calloc(1, sizeof(*c));
            if (!c) { nw_connection_cancel(connection); return; }
            c->connection = (nw_connection_t)nw_retain(connection);
            c->queue = s->nw_queue;
            dispatch_retain(c->queue);
            c->magic = BEANS_NW_TLS_MAGIC;
            pthread_mutex_lock(&s->nw_mutex);
            if (s->nw_closing) {
                pthread_mutex_unlock(&s->nw_mutex);
                beans_tls_nw_drop(c, 1);
                return;
            }
            c->all_next = s->nw_all;
            s->nw_all = c;
            pthread_mutex_unlock(&s->nw_mutex);
            nw_connection_set_queue(c->connection, c->queue);
            nw_connection_set_state_changed_handler(
                c->connection,
                ^(nw_connection_state_t state, nw_error_t error) {
                    if (state != nw_connection_state_ready &&
                        state != nw_connection_state_failed &&
                        state != nw_connection_state_cancelled) return;
                    if (state == nw_connection_state_failed && error &&
                        getenv("BEANS_TLS_DEBUG")) {
                        fprintf(stderr, "beans tls nw connection failed: domain=%d code=%d\n",
                                (int)nw_error_get_error_domain(error),
                                nw_error_get_error_code(error));
                    }
                    nw_connection_set_state_changed_handler(
                        c->connection, NULL);
                    if (state == nw_connection_state_ready)
                        beans_tls_nw_capture_alpn(c);
                    pthread_mutex_lock(&s->nw_mutex);
                    if (state == nw_connection_state_ready && !s->nw_closing) {
                        if (s->nw_tail) s->nw_tail->ready_next = c;
                        else s->nw_head = c;
                        s->nw_tail = c;
                        pthread_cond_broadcast(&s->nw_changed);
                        pthread_mutex_unlock(&s->nw_mutex);
                    } else {
                        beans_tls_nw_remove_locked(s, c);
                        pthread_cond_broadcast(&s->nw_changed);
                        pthread_mutex_unlock(&s->nw_mutex);
                        beans_tls_nw_drop(c, 0);
                    }
                });
            nw_connection_start(c->connection);
        });
    nw_listener_start(s->nw_listener);

    pthread_mutex_lock(&s->nw_mutex);
    int wait_result = 0;
    struct timespec deadline;
    const struct timespec* limit = timeout_ms > 0 &&
        beans_tls_deadline(timeout_ms, &deadline) == 0 ? &deadline : NULL;
    if (timeout_ms > 0 && !limit) wait_result = EINVAL;
    while (s->nw_state == 0 && wait_result == 0)
        wait_result = beans_tls_cond_wait_until(
            &s->nw_changed, &s->nw_mutex, limit);
    int ready = s->nw_state == 1;
    pthread_mutex_unlock(&s->nw_mutex);
    if (!ready) return wait_result == ETIMEDOUT
        ? BEANS_TLS_WANT_IO : BEANS_TLS_HANDSHAKE;
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_listener_port(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->nw_listener || !s->nw_sync_ready) return -1;
    pthread_mutex_lock(&s->nw_mutex);
    long long port = s->nw_state == 1
        ? (long long)nw_listener_get_port(s->nw_listener) : -1;
    pthread_mutex_unlock(&s->nw_mutex);
    return port;
}

// Returns an accepted, already-handshaken Network.framework connection
// handle. req is [timeout_ms, blocking]. -8 is timeout; other negative
// values follow the data-path enum.
BEANS_NET_API long long beans_tls_listener_accept(long long handle,
                                                  const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->nw_listener || !req || !s->nw_sync_ready)
        return BEANS_TLS_R_INVALID;
    uint64_t timeout_ms = beans_net_word(req, 0);
    int blocking = beans_net_word(req, 1) != 0;
    pthread_mutex_lock(&s->nw_mutex);
    int wait_result = 0;
    struct timespec deadline;
    const struct timespec* limit = !blocking && timeout_ms > 0 &&
        beans_tls_deadline(timeout_ms, &deadline) == 0 ? &deadline : NULL;
    if (!blocking && timeout_ms > 0 && !limit) wait_result = EINVAL;
    while (!s->nw_head && s->nw_state == 1 && !s->nw_closing &&
           wait_result == 0) {
        if (!blocking && timeout_ms == 0) {
            wait_result = ETIMEDOUT;
            break;
        }
        wait_result = beans_tls_cond_wait_until(
            &s->nw_changed, &s->nw_mutex, blocking ? NULL : limit);
    }
    beans_nw_connection* c = s->nw_head;
    if (c) {
        s->nw_head = c->ready_next;
        if (!s->nw_head) s->nw_tail = NULL;
        c->ready_next = NULL;
        beans_tls_nw_remove_locked(s, c);
        c->owner = s;
        atomic_fetch_add_explicit(&s->nw_refs, 1, memory_order_relaxed);
    }
    int closed = s->nw_state != 1 || s->nw_closing;
    pthread_mutex_unlock(&s->nw_mutex);
    if (c) return (long long)(intptr_t)c;
    if (wait_result == ETIMEDOUT) return -8;
    return closed ? BEANS_TLS_R_CLOSED : BEANS_TLS_R_PROTOCOL;
}

typedef struct {
    atomic_int refs;
    dispatch_semaphore_t done;
    uint8_t* data;
    size_t len;
    int status;
} beans_tls_nw_operation;

static beans_tls_nw_operation* beans_tls_nw_operation_new(void) {
    beans_tls_nw_operation* op =
        (beans_tls_nw_operation*)calloc(1, sizeof(*op));
    if (!op) return NULL;
    atomic_init(&op->refs, 2);
    op->done = dispatch_semaphore_create(0);
    op->status = BEANS_TLS_R_WANT_IO;
    if (!op->done) { free(op); return NULL; }
    return op;
}

static void beans_tls_nw_operation_drop(beans_tls_nw_operation* op) {
    if (atomic_fetch_sub_explicit(
            &op->refs, 1, memory_order_acq_rel) == 1) {
        if (op->done) dispatch_release(op->done);
        free(op->data);
        free(op);
    }
}

static int beans_tls_nw_operation_wait(beans_tls_nw_operation* op,
                                       uint64_t timeout_ms) {
    dispatch_time_t limit = timeout_ms == 0
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(timeout_ms > INT64_MAX / NSEC_PER_MSEC
                            ? INT64_MAX : timeout_ms * NSEC_PER_MSEC));
    return dispatch_semaphore_wait(op->done, limit) == 0;
}

// req: [maximum bytes, timeout_ms].
BEANS_NET_API long long beans_tls_nw_read(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    beans_nw_connection* c = beans_tls_nw_of(handle);
    if (!c || !out || !req) return BEANS_TLS_R_INVALID;
    uint64_t maximum = beans_net_word(req, 0);
    uint64_t timeout_ms = beans_net_word(req, 1);
    if (maximum == 0 || maximum > UINT32_MAX) return BEANS_TLS_R_INVALID;
    beans_tls_nw_operation* op = beans_tls_nw_operation_new();
    if (!op) return BEANS_TLS_R_PROTOCOL;
    nw_connection_receive(
        c->connection, 1, (uint32_t)maximum,
        ^(dispatch_data_t content, nw_content_context_t context,
          bool is_complete, nw_error_t error) {
            (void)context;
            if (content) {
                const void* mapped = NULL;
                size_t mapped_len = 0;
                dispatch_data_t view = dispatch_data_create_map(
                    content, &mapped, &mapped_len);
                if (view && mapped_len <= (size_t)maximum) {
                    op->data = mapped_len
                        ? (uint8_t*)malloc(mapped_len) : NULL;
                    if (mapped_len == 0 || op->data) {
                        if (mapped_len) memcpy(op->data, mapped, mapped_len);
                        op->len = mapped_len;
                        op->status = BEANS_TLS_OK;
                    } else op->status = BEANS_TLS_R_PROTOCOL;
                } else op->status = BEANS_TLS_R_PROTOCOL;
                if (view) dispatch_release(view);
            } else if (is_complete && !error) {
                op->status = BEANS_TLS_R_CLOSED;
            } else if (error) {
                op->status = BEANS_TLS_R_TRUNCATED;
            }
            dispatch_semaphore_signal(op->done);
            beans_tls_nw_operation_drop(op);
        });
    int completed = beans_tls_nw_operation_wait(op, timeout_ms);
    long long result = -8;
    if (!completed) nw_connection_cancel(c->connection);
    if (completed) {
        result = op->status == BEANS_TLS_OK
            ? (long long)op->len : op->status;
        if (op->status == BEANS_TLS_OK && op->len)
            memcpy(out, op->data, op->len);
    }
    beans_tls_nw_operation_drop(op);
    return result;
}

// req: [byte length, timeout_ms].
BEANS_NET_API long long beans_tls_nw_write(long long handle,
                                           const uint8_t* data,
                                           const uint64_t* req) {
    beans_nw_connection* c = beans_tls_nw_of(handle);
    if (!c || !req) return BEANS_TLS_R_INVALID;
    uint64_t len = beans_net_word(req, 0);
    uint64_t timeout_ms = beans_net_word(req, 1);
    if (len > SIZE_MAX || (len > 0 && !data)) return BEANS_TLS_R_INVALID;
    if (len == 0) return 0;
    void* copied = malloc((size_t)len);
    if (!copied) return BEANS_TLS_R_PROTOCOL;
    memcpy(copied, data, (size_t)len);
    dispatch_data_t content = dispatch_data_create(
        copied, (size_t)len, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    if (!content) { free(copied); return BEANS_TLS_R_PROTOCOL; }
    beans_tls_nw_operation* op = beans_tls_nw_operation_new();
    if (!op) { dispatch_release(content); return BEANS_TLS_R_PROTOCOL; }
    nw_connection_send(
        c->connection, content, NW_CONNECTION_DEFAULT_STREAM_CONTEXT, false,
        ^(nw_error_t error) {
            op->status = error ? BEANS_TLS_R_PROTOCOL : BEANS_TLS_OK;
            dispatch_semaphore_signal(op->done);
            beans_tls_nw_operation_drop(op);
        });
    dispatch_release(content);
    int completed = beans_tls_nw_operation_wait(op, timeout_ms);
    if (!completed) nw_connection_cancel(c->connection);
    long long result = completed
        ? (op->status == BEANS_TLS_OK ? (long long)len : op->status) : -8;
    beans_tls_nw_operation_drop(op);
    return result;
}

BEANS_NET_API long long beans_tls_nw_alpn(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    beans_nw_connection* c = beans_tls_nw_of(handle);
    if (!c || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    size_t len = strlen(c->alpn);
    if (len > cap) return -1;
    if (len) memcpy(out, c->alpn, len);
    return (long long)len;
}

BEANS_NET_API long long beans_tls_nw_shutdown(long long handle,
                                              const uint64_t* req) {
    beans_nw_connection* c = beans_tls_nw_of(handle);
    if (!c || !req) return BEANS_NET_ERR_INVALID;
    uint64_t timeout_ms = beans_net_word(req, 0);
    beans_tls_nw_operation* op = beans_tls_nw_operation_new();
    if (!op) return BEANS_TLS_PROTOCOL;
    nw_connection_send(
        c->connection, NULL, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true,
        ^(nw_error_t error) {
            op->status = error ? BEANS_TLS_R_PROTOCOL : BEANS_TLS_OK;
            dispatch_semaphore_signal(op->done);
            beans_tls_nw_operation_drop(op);
        });
    int completed = beans_tls_nw_operation_wait(op, timeout_ms);
    if (!completed) nw_connection_cancel(c->connection);
    long long result = completed
        ? (op->status == BEANS_TLS_OK ? BEANS_NET_OK : BEANS_TLS_PROTOCOL)
        : BEANS_TLS_WANT_IO;
    beans_tls_nw_operation_drop(op);
    return result;
}

static void beans_tls_session_destroy(beans_tls_session* s) {
    if (!s) return;
    if (s->nw_listener) nw_release(s->nw_listener);
    if (s->nw_sync_ready) {
        pthread_cond_destroy(&s->nw_changed);
        pthread_mutex_destroy(&s->nw_mutex);
    }
    if (s->nw_queue) dispatch_release(s->nw_queue);
    if (s->ctx) CFRelease(s->ctx);
    if (s->extra_roots) CFRelease(s->extra_roots);
    if (s->alpn_config) CFRelease(s->alpn_config);
    beans_tls_identity_entry* identity = s->identities;
    while (identity) {
        beans_tls_identity_entry* next = identity->next;
        if (identity->nw_identity) sec_release(identity->nw_identity);
        if (identity->chain) CFRelease(identity->chain);
        beans_tls_drop_keychain(identity->keychain,
                                identity->keychain_path);
        free(identity);
        identity = next;
    }
    free(s->incoming.data);
    free(s->outgoing.data);
    s->magic = 0;
    free(s);
}

static void beans_tls_session_release(beans_tls_session* s) {
    if (atomic_fetch_sub_explicit(
            &s->nw_refs, 1, memory_order_acq_rel) == 1)
        beans_tls_session_destroy(s);
}

BEANS_NET_API long long beans_tls_nw_free(long long handle) {
    beans_nw_connection* c = beans_tls_nw_of(handle);
    if (!c) return BEANS_NET_ERR_INVALID;
    beans_tls_session* owner = c->owner;
    beans_tls_nw_drop(c, 1);
    if (owner) beans_tls_session_release(owner);
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_close_notify(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    OSStatus rc = SSLClose(s->ctx);
    if (rc == noErr || rc == errSSLWouldBlock) return BEANS_TLS_OK;
    return BEANS_TLS_PROTOCOL;
}

BEANS_NET_API long long beans_tls_free(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (!s->nw_sync_ready) {
        beans_tls_session_release(s);
        return BEANS_NET_OK;
    }
    pthread_mutex_lock(&s->nw_mutex);
    s->nw_closing = 1;
    pthread_cond_broadcast(&s->nw_changed);
    pthread_mutex_unlock(&s->nw_mutex);
    if (s->nw_listener) {
        nw_listener_set_new_connection_handler(s->nw_listener, NULL);
        nw_listener_set_state_changed_handler(s->nw_listener, NULL);
        nw_listener_cancel(s->nw_listener);
    }
    if (s->nw_queue) {
        dispatch_sync(s->nw_queue, ^{
            pthread_mutex_lock(&s->nw_mutex);
            for (beans_nw_connection* c = s->nw_all; c; c = c->all_next) {
                nw_connection_set_state_changed_handler(c->connection, NULL);
                nw_connection_cancel(c->connection);
            }
            pthread_mutex_unlock(&s->nw_mutex);
        });
    }
    beans_nw_connection* pending = s->nw_all;
    s->nw_all = NULL;
    s->nw_head = NULL;
    s->nw_tail = NULL;
    while (pending) {
        beans_nw_connection* next = pending->all_next;
        beans_tls_nw_drop(pending, 0);
        pending = next;
    }
    // Invalidate the public listener handle now, but keep its framework
    // objects and identities alive until every accepted stream is freed.
    s->magic = 0;
    beans_tls_session_release(s);
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
#include <strings.h>

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
    long (*SSL_CTX_ctrl)(void*, int, long, void*);
    void* (*SSL_new)(void*);
    void (*SSL_free)(void*);
    void (*SSL_set_connect_state)(void*);
    void (*SSL_set_accept_state)(void*);
    void (*SSL_set_bio)(void*, void*, void*);
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
    void (*SSL_CTX_set_alpn_select_cb)(
        void*, int (*)(void*, const unsigned char**, unsigned char*,
                       const unsigned char*, unsigned int, void*), void*);
    long (*SSL_CTX_callback_ctrl)(void*, int, void (*)(void));
    const char* (*SSL_get_servername)(const void*, int);
    void* (*SSL_set_SSL_CTX)(void*, void*);
    void (*SSL_get0_alpn_selected)(const void*, const unsigned char**, unsigned int*);
    int (*SSL_CTX_use_certificate)(void*, void*);
    int (*SSL_CTX_use_PrivateKey)(void*, void*);
    int (*SSL_CTX_check_private_key)(const void*);
    int (*SSL_use_certificate)(void*, void*);
    int (*SSL_use_PrivateKey)(void*, void*);
    int (*SSL_check_private_key)(const void*);
    // BIO
    void* (*BIO_new)(const void*);
    const void* (*BIO_s_mem)(void);
    void* (*BIO_new_mem_buf)(const void*, int);
    int (*BIO_write)(void*, const void*, int);
    int (*BIO_read)(void*, void*, int);
    long (*BIO_ctrl)(void*, int, long, void*);
    void (*BIO_free_all)(void*);
    void* (*PEM_read_bio_X509)(void*, void*, void*, void*);
    void* (*PEM_read_bio_PrivateKey)(void*, void*, void*, void*);
    void (*X509_free)(void*);
    void (*EVP_PKEY_free)(void*);
    void* (*d2i_PKCS12_bio)(void*, void**);
    int (*PKCS12_parse)(void*, const char*, void**, void**, void**);
    void (*PKCS12_free)(void*);
    void (*OPENSSL_sk_pop_free)(void*, void (*)(void*));
    int (*OPENSSL_sk_num)(const void*);
    void* (*OPENSSL_sk_value)(const void*, int);
    void* (*SSL_CTX_get_cert_store)(void*);
    int (*X509_STORE_add_cert)(void*, void*);
    unsigned long (*OpenSSL_version_num)(void);
    unsigned long (*ERR_get_error)(void);
    void (*ERR_error_string_n)(unsigned long, char*, size_t);
} ossl;

static void beans_tls_load(void) {
    if (ossl.loaded) return;
    ossl.loaded = 1;
    const char* ssl_names[3];
    int sc = 0;
    const char* ov = getenv("BEANS_LIBSSL");
    if (ov && *ov) ssl_names[sc++] = ov;
    ssl_names[sc++] = "libssl.so.3";
    ssl_names[sc++] = "libssl.3.dylib";
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
    ossl.SSL_set_bio = (void(*)(void*,void*,void*))dlsym(h, "SSL_set_bio");
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
    ossl.SSL_CTX_set_alpn_select_cb =
        (void(*)(void*,int(*)(void*,const unsigned char**,unsigned char*,
                              const unsigned char*,unsigned int,void*),void*))
            dlsym(h, "SSL_CTX_set_alpn_select_cb");
    ossl.SSL_CTX_callback_ctrl =
        (long(*)(void*,int,void(*)(void)))dlsym(h, "SSL_CTX_callback_ctrl");
    ossl.SSL_get_servername =
        (const char*(*)(const void*,int))dlsym(h, "SSL_get_servername");
    ossl.SSL_set_SSL_CTX =
        (void*(*)(void*,void*))dlsym(h, "SSL_set_SSL_CTX");
    ossl.SSL_get0_alpn_selected =
        (void(*)(const void*,const unsigned char**,unsigned int*))dlsym(h, "SSL_get0_alpn_selected");
    ossl.SSL_CTX_use_certificate =
        (int(*)(void*,void*))dlsym(h, "SSL_CTX_use_certificate");
    ossl.SSL_CTX_use_PrivateKey =
        (int(*)(void*,void*))dlsym(h, "SSL_CTX_use_PrivateKey");
    ossl.SSL_CTX_check_private_key =
        (int(*)(const void*))dlsym(h, "SSL_CTX_check_private_key");
    ossl.SSL_use_certificate =
        (int(*)(void*,void*))dlsym(h, "SSL_use_certificate");
    ossl.SSL_use_PrivateKey =
        (int(*)(void*,void*))dlsym(h, "SSL_use_PrivateKey");
    ossl.SSL_check_private_key =
        (int(*)(const void*))dlsym(h, "SSL_check_private_key");
    // BIO lives in libcrypto, usually pulled in by libssl already.
    ossl.BIO_new = (void*(*)(const void*))dlsym(h, "BIO_new");
    ossl.BIO_s_mem = (const void*(*)(void))dlsym(h, "BIO_s_mem");
    ossl.BIO_new_mem_buf = (void*(*)(const void*,int))dlsym(h, "BIO_new_mem_buf");
    ossl.BIO_write = (int(*)(void*,const void*,int))dlsym(h, "BIO_write");
    ossl.BIO_read = (int(*)(void*,void*,int))dlsym(h, "BIO_read");
    ossl.BIO_ctrl = (long(*)(void*,int,long,void*))dlsym(h, "BIO_ctrl");
    ossl.BIO_free_all = (void(*)(void*))dlsym(h, "BIO_free_all");
    ossl.PEM_read_bio_X509 = (void*(*)(void*,void*,void*,void*))dlsym(h, "PEM_read_bio_X509");
    ossl.PEM_read_bio_PrivateKey =
        (void*(*)(void*,void*,void*,void*))dlsym(h, "PEM_read_bio_PrivateKey");
    ossl.X509_free = (void(*)(void*))dlsym(h, "X509_free");
    ossl.EVP_PKEY_free = (void(*)(void*))dlsym(h, "EVP_PKEY_free");
    ossl.d2i_PKCS12_bio =
        (void*(*)(void*,void**))dlsym(h, "d2i_PKCS12_bio");
    ossl.PKCS12_parse =
        (int(*)(void*,const char*,void**,void**,void**))dlsym(h, "PKCS12_parse");
    ossl.PKCS12_free = (void(*)(void*))dlsym(h, "PKCS12_free");
    ossl.OPENSSL_sk_pop_free =
        (void(*)(void*,void(*)(void*)))dlsym(h, "OPENSSL_sk_pop_free");
    ossl.OPENSSL_sk_num =
        (int(*)(const void*))dlsym(h, "OPENSSL_sk_num");
    ossl.OPENSSL_sk_value =
        (void*(*)(const void*,int))dlsym(h, "OPENSSL_sk_value");
    ossl.SSL_CTX_get_cert_store = (void*(*)(void*))dlsym(h, "SSL_CTX_get_cert_store");
    ossl.X509_STORE_add_cert = (int(*)(void*,void*))dlsym(h, "X509_STORE_add_cert");
    ossl.OpenSSL_version_num =
        (unsigned long(*)(void))dlsym(h, "OpenSSL_version_num");
    ossl.ERR_get_error = (unsigned long(*)(void))dlsym(h, "ERR_get_error");
    ossl.ERR_error_string_n =
        (void(*)(unsigned long,char*,size_t))dlsym(h, "ERR_error_string_n");
    ossl.ok = ossl.OpenSSL_version_num &&
              (ossl.OpenSSL_version_num() & 0xf0000000UL) == 0x30000000UL &&
              ossl.TLS_client_method && ossl.TLS_server_method &&
              ossl.SSL_CTX_new &&
              ossl.SSL_CTX_free && ossl.SSL_CTX_set_default_verify_paths &&
              ossl.SSL_CTX_ctrl && ossl.SSL_new && ossl.SSL_free &&
              ossl.SSL_set_connect_state && ossl.SSL_set_accept_state &&
              ossl.SSL_set_bio &&
              ossl.SSL_do_handshake && ossl.SSL_get_error &&
              ossl.SSL_read && ossl.SSL_write && ossl.SSL_shutdown &&
              ossl.SSL_ctrl && ossl.SSL_set1_host && ossl.SSL_set_verify &&
              ossl.SSL_get_verify_result && ossl.SSL_set_alpn_protos &&
              ossl.SSL_CTX_set_alpn_select_cb &&
              ossl.SSL_CTX_callback_ctrl && ossl.SSL_get_servername &&
              ossl.SSL_set_SSL_CTX &&
              ossl.SSL_get0_alpn_selected && ossl.BIO_new &&
              ossl.BIO_s_mem && ossl.BIO_new_mem_buf && ossl.BIO_write &&
              ossl.BIO_read && ossl.BIO_ctrl && ossl.BIO_free_all &&
              ossl.PEM_read_bio_X509 && ossl.PEM_read_bio_PrivateKey &&
              ossl.X509_free && ossl.EVP_PKEY_free &&
              ossl.SSL_CTX_use_certificate && ossl.SSL_CTX_use_PrivateKey &&
              ossl.SSL_CTX_check_private_key && ossl.SSL_use_certificate &&
              ossl.SSL_use_PrivateKey && ossl.SSL_check_private_key &&
              ossl.d2i_PKCS12_bio && ossl.PKCS12_parse &&
              ossl.PKCS12_free && ossl.OPENSSL_sk_pop_free &&
              ossl.OPENSSL_sk_num && ossl.OPENSSL_sk_value &&
              ossl.SSL_CTX_get_cert_store && ossl.X509_STORE_add_cert;
    if (!ossl.ok) {
        dlclose(h);
        ossl.ssl_lib = NULL;
    }
    #undef L
}

static void beans_tls_ossl_debug(const char* where, long verify) {
    if (!getenv("BEANS_TLS_DEBUG")) return;
    fprintf(stderr, "beans-tls OpenSSL %s verify=%ld", where, verify);
    if (ossl.ERR_get_error && ossl.ERR_error_string_n) {
        unsigned long code;
        while ((code = ossl.ERR_get_error()) != 0) {
            char message[256];
            ossl.ERR_error_string_n(code, message, sizeof(message));
            fprintf(stderr, " | %s", message);
        }
    }
    fputc('\n', stderr);
}

// OpenSSL constants used (stable across 1.1/3.x).
#define SSL_ERROR_SSL 1
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_ZERO_RETURN 6
#define SSL_VERIFY_PEER 1
#define BIO_CTRL_PENDING 10
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define SSL_CTRL_SET_TLSEXT_SERVERNAME_CB 53
#define SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG 54
#define SSL_CTRL_CHAIN_CERT 89
#define TLSEXT_NAMETYPE_HOST_NAME 0
#define TLS1_2_VERSION 0x0303
#define X509_V_OK 0

typedef struct beans_tls_ossl_identity {
    char name[256];
    void* ctx;
    struct beans_tls_ossl_identity* next;
} beans_tls_ossl_identity;

typedef struct {
    void* ctx;
    void* ssl;
    void* rbio; // network -> SSL (we write ciphertext in)
    void* wbio; // SSL -> network (we read ciphertext out)
    int is_server;
    int handshake_done;
    int verify_host;
    unsigned char alpn_wire[256];
    unsigned int alpn_wire_len;
    beans_tls_ossl_identity* identities;
    int has_default_identity;
    uint64_t magic;
} beans_tls_session;

#define BEANS_TLS_MAGIC 0x62656e73746c73ULL

static beans_tls_session* beans_tls_of(long long handle) {
    beans_tls_session* s = (beans_tls_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_TLS_MAGIC) return NULL;
    return s;
}

static int beans_tls_ossl_alpn(void* ssl, const unsigned char** out,
                               unsigned char* out_len,
                               const unsigned char* client,
                               unsigned int client_len, void* user) {
    (void)ssl;
    beans_tls_session* s = (beans_tls_session*)user;
    unsigned int server_at = 0;
    while (server_at < s->alpn_wire_len) {
        unsigned int server_len = s->alpn_wire[server_at++];
        if (server_len == 0 || server_len > s->alpn_wire_len - server_at)
            return 3; // SSL_TLSEXT_ERR_NOACK
        unsigned int client_at = 0;
        while (client_at < client_len) {
            unsigned int offered_len = client[client_at++];
            if (offered_len == 0 || offered_len > client_len - client_at)
                return 3;
            if (offered_len == server_len &&
                memcmp(client + client_at,
                       s->alpn_wire + server_at, server_len) == 0) {
                *out = s->alpn_wire + server_at;
                *out_len = (unsigned char)server_len;
                return 0; // SSL_TLSEXT_ERR_OK
            }
            client_at += offered_len;
        }
        server_at += server_len;
    }
    return 3;
}

// OpenSSL calls this after it has parsed ClientHello but before it chooses
// the certificate. A missing or unknown name falls back to the required
// default identity; an exact ASCII case-insensitive match switches context.
static int beans_tls_ossl_sni(void* ssl, int* alert, void* user) {
    (void)alert;
    beans_tls_session* s = (beans_tls_session*)user;
    const char* requested = ossl.SSL_get_servername(
        ssl, TLSEXT_NAMETYPE_HOST_NAME);
    if (!requested || !*requested) return 0; // SSL_TLSEXT_ERR_OK
    for (beans_tls_ossl_identity* at = s->identities; at; at = at->next) {
        if (strcasecmp(at->name, requested) == 0) {
            return ossl.SSL_set_SSL_CTX(ssl, at->ctx) ? 0 : 2;
        }
    }
    return 0;
}

static int beans_tls_ossl_server_context(beans_tls_session* s, void* ctx) {
    if (ossl.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION,
                          TLS1_2_VERSION, NULL) <= 0)
        return 0;
    if (s->alpn_wire_len > 0)
        ossl.SSL_CTX_set_alpn_select_cb(ctx, beans_tls_ossl_alpn, s);
    if (ossl.SSL_CTX_callback_ctrl(
            ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB,
            (void (*)(void))beans_tls_ossl_sni) <= 0 ||
        ossl.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG,
                          0, s) <= 0)
        return 0;
    return 1;
}

BEANS_NET_API long long beans_tls_client_new(const uint8_t* host,
                                             const uint8_t* alpn,
                                             const uint64_t* req) {
    if (!req) return 0;
    uint64_t role = beans_net_word(req, 0);
    uint64_t host_len = beans_net_word(req, 1);
    uint64_t alpn_len = beans_net_word(req, 2);
    if (role > 1 || host_len > SIZE_MAX || alpn_len > SIZE_MAX ||
        (!role && (!host || host_len == 0)) ||
        (host_len > 0 && !host) || (alpn_len > 0 && !alpn)) return 0;
    beans_tls_load();
    if (!ossl.ok) return 0;
    beans_tls_session* s = (beans_tls_session*)calloc(1, sizeof(beans_tls_session));
    if (!s) return 0;
    s->is_server = (int)role;
    const void* method = s->is_server ? (ossl.TLS_server_method ? ossl.TLS_server_method() : NULL)
                                      : ossl.TLS_client_method();
    if (!method) { free(s); return 0; }
    s->ctx = ossl.SSL_CTX_new(method);
    if (!s->ctx) { free(s); return 0; }
    if (!s->is_server && ossl.SSL_CTX_set_default_verify_paths(s->ctx) != 1) {
        ossl.SSL_CTX_free(s->ctx);
        free(s);
        return 0;
    }
    // Refuse < TLS 1.2 at the context.
    if (ossl.SSL_CTX_ctrl(s->ctx, SSL_CTRL_SET_MIN_PROTO_VERSION,
                          TLS1_2_VERSION, NULL) <= 0) {
        ossl.SSL_CTX_free(s->ctx);
        free(s);
        return 0;
    }
    s->ssl = ossl.SSL_new(s->ctx);
    if (!s->ssl) { ossl.SSL_CTX_free(s->ctx); free(s); return 0; }
    s->rbio = ossl.BIO_new(ossl.BIO_s_mem());
    s->wbio = ossl.BIO_new(ossl.BIO_s_mem());
    if (!s->rbio || !s->wbio) {
        if (s->rbio) ossl.BIO_free_all(s->rbio);
        if (s->wbio) ossl.BIO_free_all(s->wbio);
        ossl.SSL_free(s->ssl);
        ossl.SSL_CTX_free(s->ctx);
        free(s);
        return 0;
    }
    ossl.SSL_set_bio(s->ssl, s->rbio, s->wbio);
    if (s->is_server) {
        ossl.SSL_set_accept_state(s->ssl);
    } else {
        ossl.SSL_set_connect_state(s->ssl);
        // A name that does not fit must fail the session, never skip the
        // check: silently dropping SSL_set1_host here would leave a verified
        // chain with no hostname binding at all.
        if (host && host_len > 0) {
            char name[256];
            if (host_len >= sizeof name) {
                ossl.SSL_free(s->ssl);
                ossl.SSL_CTX_free(s->ctx);
                free(s);
                return 0;
            }
            memcpy(name, host, (size_t)host_len);
            name[host_len] = 0;
            // Enables hostname verification through the platform verifier.
            if (ossl.SSL_set1_host(s->ssl, name) != 1 ||
                ossl.SSL_ctrl(s->ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME,
                              TLSEXT_NAMETYPE_HOST_NAME, name) <= 0) {
                ossl.SSL_free(s->ssl);
                ossl.SSL_CTX_free(s->ctx);
                free(s);
                return 0;
            }
            s->verify_host = 1;
        } else {
            ossl.SSL_free(s->ssl);
            ossl.SSL_CTX_free(s->ctx);
            free(s);
            return 0;
        }
        ossl.SSL_set_verify(s->ssl, SSL_VERIFY_PEER, NULL);
    }
    if (alpn_len > 0) {
        // OpenSSL wants length-prefixed protocol names; rebuild from the
        // comma list.
        unsigned int w = 0;
        size_t start = 0;
        if (alpn_len >= sizeof s->alpn_wire) {
            ossl.SSL_free(s->ssl);
            ossl.SSL_CTX_free(s->ctx);
            free(s);
            return 0;
        }
        int valid = 1;
        for (size_t i = 0; i <= alpn_len; i++) {
            if (i == alpn_len || alpn[i] == ',') {
                size_t plen = i - start;
                if (plen > 0 && plen <= 255 &&
                    w + 1 + plen <= sizeof s->alpn_wire) {
                    s->alpn_wire[w++] = (unsigned char)plen;
                    memcpy(s->alpn_wire + w, alpn + start, plen);
                    w += (unsigned int)plen;
                } else valid = 0;
                start = i + 1;
            }
        }
        s->alpn_wire_len = w;
        if (!valid) {
            ossl.SSL_free(s->ssl);
            ossl.SSL_CTX_free(s->ctx);
            free(s);
            return 0;
        }
        if (!s->is_server && ossl.SSL_set_alpn_protos(
                       s->ssl, s->alpn_wire, w) != 0) {
            ossl.SSL_free(s->ssl);
            ossl.SSL_CTX_free(s->ctx);
            free(s);
            return 0;
        }
    }
    if (s->is_server && !beans_tls_ossl_server_context(s, s->ctx)) {
        ossl.SSL_free(s->ssl);
        ossl.SSL_CTX_free(s->ctx);
        free(s);
        return 0;
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
    if (len == 0 || len > (uint64_t)INT_MAX) return BEANS_NET_ERR_INVALID;
    void* bio = ossl.BIO_new_mem_buf(data, (int)len);
    if (!bio) return BEANS_NET_ERR_MEMORY;
    void* store = ossl.SSL_CTX_get_cert_store(s->ctx);
    if (!store) { ossl.BIO_free_all(bio); return BEANS_NET_ERR_INVALID; }
    int added = 0;
    for (;;) {
        void* cert = ossl.PEM_read_bio_X509(bio, NULL, NULL, NULL);
        if (!cert) break;
        int accepted = ossl.X509_STORE_add_cert(store, cert);
        ossl.X509_free(cert);
        if (accepted == 1) added++;
    }
    if (ossl.BIO_free_all) ossl.BIO_free_all(bio);
    return added > 0 ? BEANS_NET_OK : BEANS_NET_ERR_INVALID;
}

static int beans_tls_ossl_install_context(void* ctx, void* certificate,
                                          void* private_key) {
    return certificate && private_key &&
           ossl.SSL_CTX_use_certificate(ctx, certificate) == 1 &&
           ossl.SSL_CTX_use_PrivateKey(ctx, private_key) == 1 &&
           ossl.SSL_CTX_check_private_key(ctx) == 1;
}

static int beans_tls_ossl_install_default(beans_tls_session* s,
                                          void* certificate,
                                          void* private_key) {
    return beans_tls_ossl_install_context(
               s->ctx, certificate, private_key) &&
           ossl.SSL_use_certificate(s->ssl, certificate) == 1 &&
           ossl.SSL_use_PrivateKey(s->ssl, private_key) == 1 &&
           ossl.SSL_check_private_key(s->ssl) == 1;
}

static int beans_tls_ossl_add_chain(beans_tls_session* s, void* ctx,
                                    int is_default, void* certificate) {
    if (ossl.SSL_CTX_ctrl(ctx, SSL_CTRL_CHAIN_CERT, 1, certificate) <= 0)
        return 0;
    if (is_default &&
        ossl.SSL_ctrl(s->ssl, SSL_CTRL_CHAIN_CERT, 1, certificate) <= 0)
        return 0;
    return 1;
}

// Adds a default or named SNI identity from PEM or PKCS#12. The byte layout
// is shared with the SecureTransport backend.
BEANS_NET_API long long beans_tls_add_identity(long long handle,
                                               const uint8_t* blob,
                                               const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->is_server || !blob || !req || s->handshake_done)
        return BEANS_NET_ERR_INVALID;
    uint64_t format = beans_net_word(req, 0);
    uint64_t name_len = beans_net_word(req, 1);
    uint64_t cert_len = beans_net_word(req, 2);
    uint64_t key_len = beans_net_word(req, 3);
    uint64_t password_len = beans_net_word(req, 4);
    if (format > 1 || name_len >= 256 || cert_len == 0 ||
        (format == 0 && key_len == 0) || cert_len > INT_MAX ||
        key_len > INT_MAX || password_len > INT_MAX)
        return BEANS_NET_ERR_INVALID;
    size_t total = (size_t)name_len;
    if ((size_t)cert_len > SIZE_MAX - total)
        return BEANS_NET_ERR_RANGE;
    total += (size_t)cert_len;
    if ((size_t)key_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    total += (size_t)key_len;
    if ((size_t)password_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    for (size_t i = 0; i < (size_t)name_len; i++)
        if (blob[i] == 0) return BEANS_NET_ERR_INVALID;
    if (name_len == 0) {
        if (s->has_default_identity) return BEANS_NET_ERR_INVALID;
    } else {
        for (beans_tls_ossl_identity* at = s->identities;
             at; at = at->next) {
            if (strlen(at->name) == (size_t)name_len &&
                strncasecmp(at->name, (const char*)blob,
                            (size_t)name_len) == 0)
                return BEANS_NET_ERR_INVALID;
        }
    }
    const uint8_t* cert_data = blob + name_len;
    const uint8_t* key_data = cert_data + cert_len;
    const uint8_t* password_data = key_data + key_len;
    char* password = (char*)malloc((size_t)password_len + 1);
    if (!password) return BEANS_NET_ERR_MEMORY;
    if (password_len) memcpy(password, password_data, (size_t)password_len);
    password[password_len] = 0;

    void* certificate = NULL;
    void* private_key = NULL;
    void* extra_chain = NULL;
    void* cert_bio = NULL;
    if (format == 0) {
        cert_bio = ossl.BIO_new_mem_buf(cert_data, (int)cert_len);
        void* key_bio = ossl.BIO_new_mem_buf(key_data, (int)key_len);
        if (cert_bio)
            certificate = ossl.PEM_read_bio_X509(
                cert_bio, NULL, NULL, NULL);
        if (key_bio)
            private_key = ossl.PEM_read_bio_PrivateKey(
                key_bio, NULL, NULL, password_len ? password : NULL);
        if (key_bio) ossl.BIO_free_all(key_bio);
    } else {
        void* p12_bio = ossl.BIO_new_mem_buf(cert_data, (int)cert_len);
        void* p12 = p12_bio ? ossl.d2i_PKCS12_bio(p12_bio, NULL) : NULL;
        if (p12)
            (void)ossl.PKCS12_parse(
                p12, password, &private_key, &certificate, &extra_chain);
        if (p12) ossl.PKCS12_free(p12);
        if (p12_bio) ossl.BIO_free_all(p12_bio);
    }
    int is_default = name_len == 0;
    void* target_ctx = s->ctx;
    beans_tls_ossl_identity* entry = NULL;
    if (!is_default && certificate && private_key) {
        entry = (beans_tls_ossl_identity*)calloc(1, sizeof(*entry));
        const void* method = ossl.TLS_server_method();
        if (entry && method) entry->ctx = ossl.SSL_CTX_new(method);
        if (!entry || !entry->ctx ||
            !beans_tls_ossl_server_context(s, entry->ctx)) {
            if (entry && entry->ctx) ossl.SSL_CTX_free(entry->ctx);
            free(entry);
            entry = NULL;
        } else {
            memcpy(entry->name, blob, (size_t)name_len);
            entry->name[name_len] = 0;
            target_ctx = entry->ctx;
        }
    }
    int installed = entry || is_default
        ? (is_default
            ? beans_tls_ossl_install_default(s, certificate, private_key)
            : beans_tls_ossl_install_context(
                  target_ctx, certificate, private_key))
        : 0;
    if (installed && format == 0 && cert_bio) {
        for (;;) {
            void* extra = ossl.PEM_read_bio_X509(
                cert_bio, NULL, NULL, NULL);
            if (!extra) break;
            if (!beans_tls_ossl_add_chain(
                    s, target_ctx, is_default, extra))
                installed = 0;
            ossl.X509_free(extra);
            if (!installed) break;
        }
    }
    if (installed && extra_chain) {
        int count = ossl.OPENSSL_sk_num(extra_chain);
        for (int i = 0; i < count; i++) {
            void* extra = ossl.OPENSSL_sk_value(extra_chain, i);
            if (!extra || !beans_tls_ossl_add_chain(
                    s, target_ctx, is_default, extra)) {
                installed = 0;
                break;
            }
        }
    }
    if (cert_bio) ossl.BIO_free_all(cert_bio);
    if (extra_chain)
        ossl.OPENSSL_sk_pop_free(extra_chain, ossl.X509_free);
    if (certificate) ossl.X509_free(certificate);
    if (private_key) ossl.EVP_PKEY_free(private_key);
    free(password);
    if (!installed && entry) {
        ossl.SSL_CTX_free(entry->ctx);
        free(entry);
    } else if (installed && entry) {
        entry->next = s->identities;
        s->identities = entry;
    } else if (installed) {
        s->has_default_identity = 1;
    }
    return installed ? BEANS_NET_OK : BEANS_NET_ERR_INVALID;
}

BEANS_NET_API long long beans_tls_feed(long long handle, const uint8_t* data,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_TLS_OK;
    if (!data) return BEANS_NET_ERR_INVALID;
    if (len > SIZE_MAX) return BEANS_NET_ERR_RANGE;
    size_t done = 0;
    while (done < (size_t)len) {
        size_t left = (size_t)len - done;
        int chunk = left > (size_t)INT_MAX ? INT_MAX : (int)left;
        int wrote = ossl.BIO_write(s->rbio, data + done, chunk);
        if (wrote <= 0) return BEANS_TLS_PROTOCOL;
        done += (size_t)wrote;
    }
    return BEANS_TLS_OK;
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
    uint64_t cap = beans_net_word(req, 0);
    if (cap > (uint64_t)INT_MAX) cap = INT_MAX;
    int got = ossl.BIO_read(s->wbio, out, (int)cap);
    return got < 0 ? 0 : (long long)got;
}

BEANS_NET_API long long beans_tls_handshake(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    int rc = ossl.SSL_do_handshake(s->ssl);
    if (rc == 1) {
        if (s->verify_host && !s->is_server) {
            long verify = ossl.SSL_get_verify_result(s->ssl);
            if (verify != X509_V_OK) {
                beans_tls_ossl_debug("verify", verify);
                return BEANS_TLS_HANDSHAKE;
            }
        }
        s->handshake_done = 1;
        return BEANS_TLS_OK;
    }
    int err = ossl.SSL_get_error(s->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE)
        return BEANS_TLS_WANT_IO;
    beans_tls_ossl_debug("handshake", ossl.SSL_get_verify_result(s->ssl));
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
    if ((uint64_t)plen <= beans_net_word(req, 0)) {
        memcpy(out, proto, plen);
        return (long long)plen;
    }
    return 0;
}

// Writes app data. Return: bytes accepted (>=0), or a negative sentinel --
// never a status code, or a 111-byte write would read back as an error.
BEANS_NET_API long long beans_tls_write(long long handle, const uint8_t* data,
                                        const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_TLS_R_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return 0;
    if (!data) return BEANS_TLS_R_INVALID;
    if (len > (uint64_t)INT_MAX) len = (uint64_t)INT_MAX;
    int wrote = ossl.SSL_write(s->ssl, data, (int)len);
    if (wrote > 0) return (long long)wrote;
    int err = ossl.SSL_get_error(s->ssl, wrote);
    if (err == SSL_ERROR_WANT_READ) return BEANS_TLS_R_WANT_IO;
    if (err == SSL_ERROR_WANT_WRITE) return BEANS_TLS_R_WANT_WRITE;
    return BEANS_TLS_R_PROTOCOL;
}

BEANS_NET_API long long beans_tls_read(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return BEANS_TLS_R_INVALID;
    uint64_t want = beans_net_word(req, 0);
    if (want > (uint64_t)INT_MAX) want = (uint64_t)INT_MAX;
    int got = ossl.SSL_read(s->ssl, out, (int)want);
    if (got > 0) return (long long)got;
    int err = ossl.SSL_get_error(s->ssl, got);
    if (err == SSL_ERROR_WANT_READ) return BEANS_TLS_R_WANT_IO;
    if (err == SSL_ERROR_WANT_WRITE) return BEANS_TLS_R_WANT_WRITE;
    if (err == SSL_ERROR_ZERO_RETURN) return BEANS_TLS_R_CLOSED;
    // A record-layer failure -- bad MAC, bad record, a fatal alert -- is
    // active tampering, not a truncated stream. Reporting it as a plain cut
    // hides the one case an operator most needs to see.
    if (err == SSL_ERROR_SSL) return BEANS_TLS_R_PROTOCOL;
    return BEANS_TLS_R_TRUNCATED;
}

BEANS_NET_API long long beans_tls_close_notify(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    int rc = ossl.SSL_shutdown(s->ssl);
    if (rc >= 0) return BEANS_TLS_OK;
    int err = ossl.SSL_get_error(s->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE)
        return BEANS_TLS_OK;
    return BEANS_TLS_PROTOCOL;
}

BEANS_NET_API long long beans_tls_free(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->ssl) ossl.SSL_free(s->ssl);   // frees the BIOs it owns
    beans_tls_ossl_identity* identity = s->identities;
    while (identity) {
        beans_tls_ossl_identity* next = identity->next;
        if (identity->ctx) ossl.SSL_CTX_free(identity->ctx);
        free(identity);
        identity = next;
    }
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
// SChannel. Like the other backends, SSPI never owns the socket: encrypted
// input and output stay in memory queues and Beans drives all network IO.
#define SECURITY_WIN32
#include <windows.h>
#include <security.h>
#include <schannel.h>
#include <wincrypt.h>
#include <ncrypt.h>
#include <wchar.h>

typedef struct beans_tls_schannel_identity {
    char name[256];
    PCCERT_CONTEXT certificate;
    HCERTSTORE store;
    NCRYPT_PROV_HANDLE key_provider;
    NCRYPT_KEY_HANDLE key;
    CredHandle credential;
    int credential_valid;
    struct beans_tls_schannel_identity* next;
} beans_tls_schannel_identity;

typedef struct {
    CredHandle credential;
    int credential_valid;
    CtxtHandle context;
    int context_valid;
    int is_server;
    int handshake_done;
    int verified;
    int closed;
    int close_sent;
    wchar_t host[256];
    beans_tls_buf incoming;
    beans_tls_buf outgoing;
    beans_tls_buf plaintext;
    HCERTSTORE extra_roots;
    beans_tls_schannel_identity* identities;
    beans_tls_schannel_identity* default_identity;
    beans_tls_schannel_identity* selected_identity;
    SecPkgContext_StreamSizes sizes;
    unsigned char alpn_wire[256];
    unsigned int alpn_wire_len;
    uint64_t magic;
} beans_tls_session;

#define BEANS_TLS_MAGIC 0x62656e73746c73ULL

static beans_tls_session* beans_tls_of(long long handle) {
    beans_tls_session* s = (beans_tls_session*)(intptr_t)handle;
    if (!s || s->magic != BEANS_TLS_MAGIC) return NULL;
    return s;
}

static void beans_tls_win_debug(const char* where, long status) {
    if (!getenv("BEANS_TLS_DEBUG")) return;
    fprintf(stderr, "beans-tls SChannel %s status=0x%lx last=0x%lx\n",
            where, (unsigned long)status, (unsigned long)GetLastError());
}

static void beans_tls_buf_discard(beans_tls_buf* b, size_t count) {
    size_t have = beans_tls_buf_available(b);
    if (count > have) count = have;
    b->head += count;
    if (b->head == b->len) { b->head = 0; b->len = 0; }
}

static const uint8_t* beans_tls_win_find(const uint8_t* data, size_t len,
                                         const char* wanted) {
    size_t wanted_len = strlen(wanted);
    if (wanted_len == 0 || wanted_len > len) return NULL;
    for (size_t i = 0; i + wanted_len <= len; i++)
        if (memcmp(data + i, wanted, wanted_len) == 0) return data + i;
    return NULL;
}

static wchar_t* beans_tls_win_wide(const uint8_t* text, size_t len) {
    if (!text || len == 0 || len > INT_MAX) return NULL;
    int needed = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, (const char*)text, (int)len, NULL, 0);
    if (needed <= 0 || needed >= 32767) return NULL;
    wchar_t* result = (wchar_t*)calloc((size_t)needed + 1, sizeof(wchar_t));
    if (!result) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                            (const char*)text, (int)len,
                            result, needed) != needed) {
        free(result);
        return NULL;
    }
    return result;
}

static int beans_tls_win_protocols(beans_tls_session* s,
                                   const uint8_t* list, size_t len) {
    if (len == 0) return 1;
    if (!list || len >= sizeof s->alpn_wire) return 0;
    unsigned int written = 0;
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i == len || list[i] == ',') {
            size_t part = i - start;
            if (part == 0 || part > 255 ||
                written + 1 + part > sizeof s->alpn_wire)
                return 0;
            s->alpn_wire[written++] = (unsigned char)part;
            memcpy(s->alpn_wire + written, list + start, part);
            written += (unsigned int)part;
            start = i + 1;
        }
    }
    s->alpn_wire_len = written;
    return 1;
}

static int beans_tls_win_acquire_client(beans_tls_session* s) {
    SCHANNEL_CRED config;
    memset(&config, 0, sizeof config);
    config.dwVersion = SCHANNEL_CRED_VERSION;
    config.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT;
#ifdef SP_PROT_TLS1_3_CLIENT
    config.grbitEnabledProtocols |= SP_PROT_TLS1_3_CLIENT;
#endif
    config.dwFlags = SCH_CRED_MANUAL_CRED_VALIDATION |
                     SCH_CRED_NO_DEFAULT_CREDS;
#ifdef SCH_USE_STRONG_CRYPTO
    config.dwFlags |= SCH_USE_STRONG_CRYPTO;
#endif
    TimeStamp expiry;
    SECURITY_STATUS status = AcquireCredentialsHandleW(
        NULL, UNISP_NAME_W, SECPKG_CRED_OUTBOUND, NULL, &config,
        NULL, NULL, &s->credential, &expiry);
    s->credential_valid = status == SEC_E_OK;
    return s->credential_valid;
}

static int beans_tls_win_acquire_server(
        beans_tls_schannel_identity* identity) {
    SCHANNEL_CRED config;
    memset(&config, 0, sizeof config);
    config.dwVersion = SCHANNEL_CRED_VERSION;
    config.cCreds = 1;
    config.paCred = &identity->certificate;
    config.grbitEnabledProtocols = SP_PROT_TLS1_2_SERVER;
#ifdef SP_PROT_TLS1_3_SERVER
    config.grbitEnabledProtocols |= SP_PROT_TLS1_3_SERVER;
#endif
    config.dwFlags = SCH_CRED_NO_SYSTEM_MAPPER;
#ifdef SCH_USE_STRONG_CRYPTO
    config.dwFlags |= SCH_USE_STRONG_CRYPTO;
#endif
    TimeStamp expiry;
    SECURITY_STATUS status = AcquireCredentialsHandleW(
        NULL, UNISP_NAME_W, SECPKG_CRED_INBOUND, NULL, &config,
        NULL, NULL, &identity->credential, &expiry);
    identity->credential_valid = status == SEC_E_OK;
    if (!identity->credential_valid)
        beans_tls_win_debug("server credentials", status);
    return identity->credential_valid;
}

BEANS_NET_API long long beans_tls_client_new(const uint8_t* host,
                                             const uint8_t* alpn,
                                             const uint64_t* req) {
    if (!req) return 0;
    uint64_t role = beans_net_word(req, 0);
    uint64_t host_len = beans_net_word(req, 1);
    uint64_t alpn_len = beans_net_word(req, 2);
    if (role > 1 || host_len > SIZE_MAX || alpn_len > SIZE_MAX ||
        (!role && (!host || host_len == 0)) ||
        (host_len > 0 && !host) || (alpn_len > 0 && !alpn)) return 0;
    beans_tls_session* s = (beans_tls_session*)calloc(1, sizeof(*s));
    if (!s) return 0;
    s->is_server = (int)role;
    if (!beans_tls_win_protocols(s, alpn, (size_t)alpn_len)) {
        free(s);
        return 0;
    }
    if (!s->is_server) {
        wchar_t* wide = beans_tls_win_wide(host, (size_t)host_len);
        if (!wide || wcslen(wide) >= sizeof s->host / sizeof s->host[0]) {
            free(wide);
            free(s);
            return 0;
        }
        wcscpy(s->host, wide);
        free(wide);
        if (!beans_tls_win_acquire_client(s)) { free(s); return 0; }
    }
    s->magic = BEANS_TLS_MAGIC;
    return (long long)(intptr_t)s;
}

static int beans_tls_win_add_cert(beans_tls_session* s,
                                  const uint8_t* der, size_t len) {
    if (len == 0 || len > UINT32_MAX) return 0;
    PCCERT_CONTEXT cert = CertCreateCertificateContext(
        X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, der, (DWORD)len);
    if (!cert) return 0;
    if (!s->extra_roots) {
        s->extra_roots = CertOpenStore(
            CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, NULL);
    }
    int ok = s->extra_roots && CertAddCertificateContextToStore(
        s->extra_roots, cert, CERT_STORE_ADD_USE_EXISTING, NULL);
    CertFreeCertificateContext(cert);
    return ok;
}

static uint8_t* beans_tls_win_unarmor(const uint8_t* text, size_t len,
                                      size_t* der_len) {
    if (!text || len == 0 || len > UINT32_MAX) return NULL;
    DWORD needed = 0;
    if (!CryptStringToBinaryA((const char*)text, (DWORD)len,
                              CRYPT_STRING_BASE64HEADER,
                              NULL, &needed, NULL, NULL) || needed == 0)
        return NULL;
    uint8_t* der = (uint8_t*)malloc(needed);
    if (!der) return NULL;
    if (!CryptStringToBinaryA((const char*)text, (DWORD)len,
                              CRYPT_STRING_BASE64HEADER,
                              der, &needed, NULL, NULL)) {
        free(der);
        return NULL;
    }
    *der_len = (size_t)needed;
    return der;
}

BEANS_NET_API long long beans_tls_add_root(long long handle,
                                           const uint8_t* data,
                                           const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || s->is_server || !data || !req || s->handshake_done)
        return BEANS_NET_ERR_INVALID;
    uint64_t raw_len = beans_net_word(req, 0);
    if (raw_len == 0 || raw_len > SIZE_MAX) return BEANS_NET_ERR_INVALID;
    size_t len = (size_t)raw_len;
    const char* begin_label = "-----BEGIN CERTIFICATE-----";
    const char* end_label = "-----END CERTIFICATE-----";
    const uint8_t* cursor = data;
    const uint8_t* limit = data + len;
    int added = 0;
    while (cursor < limit) {
        const uint8_t* begin = beans_tls_win_find(
            cursor, (size_t)(limit - cursor), begin_label);
        if (!begin) break;
        const uint8_t* end = beans_tls_win_find(
            begin, (size_t)(limit - begin), end_label);
        if (!end) return BEANS_NET_ERR_INVALID;
        end += strlen(end_label);
        size_t der_len = 0;
        uint8_t* der = beans_tls_win_unarmor(
            begin, (size_t)(end - begin), &der_len);
        if (!der || !beans_tls_win_add_cert(s, der, der_len)) {
            free(der);
            return BEANS_NET_ERR_INVALID;
        }
        free(der);
        added++;
        cursor = end;
    }
    if (added == 0) {
        return beans_tls_win_add_cert(s, data, len)
            ? BEANS_NET_OK : BEANS_NET_ERR_INVALID;
    }
    return BEANS_NET_OK;
}

static size_t beans_tls_win_der_len_size(size_t len) {
    if (len < 128) return 1;
    size_t bytes = 0;
    for (size_t at = len; at; at >>= 8) bytes++;
    return 1 + bytes;
}

static size_t beans_tls_win_der_len(uint8_t* out, size_t len) {
    if (len < 128) { out[0] = (uint8_t)len; return 1; }
    size_t bytes = 0;
    for (size_t at = len; at; at >>= 8) bytes++;
    out[0] = (uint8_t)(0x80 | bytes);
    for (size_t i = 0; i < bytes; i++)
        out[1 + i] = (uint8_t)(len >> (8 * (bytes - i - 1)));
    return 1 + bytes;
}

// Wraps a PKCS#1 RSA key in the small PKCS#8 envelope NCrypt accepts.
static uint8_t* beans_tls_win_wrap_rsa(const uint8_t* key, size_t key_len,
                                       size_t* out_len) {
    static const uint8_t version_and_algorithm[] = {
        0x02, 0x01, 0x00,
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
    };
    size_t octet_len_size = beans_tls_win_der_len_size(key_len);
    if (key_len > SIZE_MAX - 1 - octet_len_size -
                      sizeof version_and_algorithm) return NULL;
    size_t content_len = sizeof version_and_algorithm + 1 +
                         octet_len_size + key_len;
    size_t outer_len_size = beans_tls_win_der_len_size(content_len);
    if (content_len > SIZE_MAX - 1 - outer_len_size) return NULL;
    size_t total = 1 + outer_len_size + content_len;
    uint8_t* result = (uint8_t*)malloc(total);
    if (!result) return NULL;
    size_t at = 0;
    result[at++] = 0x30;
    at += beans_tls_win_der_len(result + at, content_len);
    memcpy(result + at, version_and_algorithm,
           sizeof version_and_algorithm);
    at += sizeof version_and_algorithm;
    result[at++] = 0x04;
    at += beans_tls_win_der_len(result + at, key_len);
    memcpy(result + at, key, key_len);
    *out_len = total;
    return result;
}

static int beans_tls_win_import_key(beans_tls_schannel_identity* identity,
                                    const uint8_t* pem, size_t pem_len,
                                    const uint8_t* password,
                                    size_t password_len) {
    size_t der_len = 0;
    uint8_t* der = beans_tls_win_unarmor(pem, pem_len, &der_len);
    if (!der) return 0;
    if (beans_tls_win_find(pem, pem_len, "BEGIN RSA PRIVATE KEY")) {
        size_t wrapped_len = 0;
        uint8_t* wrapped = beans_tls_win_wrap_rsa(
            der, der_len, &wrapped_len);
        free(der);
        der = wrapped;
        der_len = wrapped_len;
        if (!der) return 0;
    }
    SECURITY_STATUS status = NCryptOpenStorageProvider(
        &identity->key_provider, MS_KEY_STORAGE_PROVIDER, 0);
    if (status != ERROR_SUCCESS) {
        beans_tls_win_debug("open key provider", status);
        free(der);
        return 0;
    }
    NCryptBuffer buffer;
    NCryptBufferDesc description;
    void* parameters = NULL;
    wchar_t* wide_password = NULL;
    memset(&buffer, 0, sizeof buffer);
    memset(&description, 0, sizeof description);
    if (password_len > 0) {
        wide_password = beans_tls_win_wide(password, password_len);
        if (!wide_password) { free(der); return 0; }
        buffer.BufferType = NCRYPTBUFFER_PKCS_SECRET;
        buffer.pvBuffer = wide_password;
        buffer.cbBuffer = (ULONG)((wcslen(wide_password) + 1) *
                                  sizeof(wchar_t));
        description.ulVersion = NCRYPTBUFFER_VERSION;
        description.cBuffers = 1;
        description.pBuffers = &buffer;
        parameters = &description;
    }
    status = NCryptImportKey(
        identity->key_provider, 0, NCRYPT_PKCS8_PRIVATE_KEY_BLOB,
        (NCryptBufferDesc*)parameters, &identity->key,
        der, (DWORD)der_len, 0);
    free(wide_password);
    free(der);
    if (status != ERROR_SUCCESS)
        beans_tls_win_debug("import private key", status);
    return status == ERROR_SUCCESS;
}

static int beans_tls_win_pem_identity(
        beans_tls_schannel_identity* identity,
        const uint8_t* certs, size_t certs_len,
        const uint8_t* key, size_t key_len,
        const uint8_t* password, size_t password_len) {
    identity->store = CertOpenStore(
        CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, NULL);
    if (!identity->store || !beans_tls_win_import_key(
            identity, key, key_len, password, password_len)) return 0;
    const char* begin_label = "-----BEGIN CERTIFICATE-----";
    const char* end_label = "-----END CERTIFICATE-----";
    const uint8_t* cursor = certs;
    const uint8_t* limit = certs + certs_len;
    int count = 0;
    while (cursor < limit) {
        const uint8_t* begin = beans_tls_win_find(
            cursor, (size_t)(limit - cursor), begin_label);
        if (!begin) break;
        const uint8_t* end = beans_tls_win_find(
            begin, (size_t)(limit - begin), end_label);
        if (!end) return 0;
        end += strlen(end_label);
        size_t der_len = 0;
        uint8_t* der = beans_tls_win_unarmor(
            begin, (size_t)(end - begin), &der_len);
        PCCERT_CONTEXT parsed = der ? CertCreateCertificateContext(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            der, (DWORD)der_len) : NULL;
        free(der);
        if (!parsed) return 0;
        if (count == 0) {
            NCRYPT_KEY_HANDLE key_handle = identity->key;
            if (!CertSetCertificateContextProperty(
                    parsed, CERT_NCRYPT_KEY_HANDLE_PROP_ID,
                    CERT_SET_PROPERTY_INHIBIT_PERSIST_FLAG, &key_handle) ||
                !CertAddCertificateContextToStore(
                    identity->store, parsed, CERT_STORE_ADD_ALWAYS,
                    &identity->certificate)) {
                beans_tls_win_debug("attach PEM private key", GetLastError());
                CertFreeCertificateContext(parsed);
                return 0;
            }
        } else if (!CertAddCertificateContextToStore(
                       identity->store, parsed, CERT_STORE_ADD_ALWAYS, NULL)) {
            CertFreeCertificateContext(parsed);
            return 0;
        }
        CertFreeCertificateContext(parsed);
        count++;
        cursor = end;
    }
    return count > 0 && identity->certificate;
}

static int beans_tls_win_pfx_identity(
        beans_tls_schannel_identity* identity,
        const uint8_t* pfx, size_t pfx_len,
        const uint8_t* password, size_t password_len) {
    if (pfx_len == 0 || pfx_len > UINT32_MAX) return 0;
    wchar_t* wide_password = password_len
        ? beans_tls_win_wide(password, password_len) : NULL;
    if (password_len && !wide_password) return 0;
    CRYPT_DATA_BLOB blob;
    blob.cbData = (DWORD)pfx_len;
    blob.pbData = (BYTE*)pfx;
    DWORD flags = PKCS12_ALWAYS_CNG_KSP;
#ifdef PKCS12_NO_PERSIST_KEY
    flags |= PKCS12_NO_PERSIST_KEY;
#endif
    identity->store = PFXImportCertStore(&blob,
        wide_password ? wide_password : L"", flags);
    free(wide_password);
    if (!identity->store) {
        beans_tls_win_debug("import PKCS12", GetLastError());
        return 0;
    }
    PCCERT_CONTEXT at = NULL;
    while ((at = CertEnumCertificatesInStore(identity->store, at)) != NULL) {
        HCRYPTPROV_OR_NCRYPT_KEY_HANDLE key_handle = 0;
        DWORD key_spec = 0;
        BOOL caller_frees = FALSE;
        if (CryptAcquireCertificatePrivateKey(
                at, CRYPT_ACQUIRE_SILENT_FLAG |
                    CRYPT_ACQUIRE_ALLOW_NCRYPT_KEY_FLAG,
                NULL, &key_handle, &key_spec, &caller_frees)) {
            if (caller_frees) {
                if (key_spec == CERT_NCRYPT_KEY_SPEC)
                    NCryptFreeObject((NCRYPT_HANDLE)key_handle);
                else
                    CryptReleaseContext((HCRYPTPROV)key_handle, 0);
            }
            identity->certificate = CertDuplicateCertificateContext(at);
            break;
        }
    }
    if (!identity->certificate)
        beans_tls_win_debug("find PKCS12 private key", GetLastError());
    return identity->certificate != NULL;
}

static void beans_tls_win_free_identity(
        beans_tls_schannel_identity* identity) {
    if (!identity) return;
    if (identity->credential_valid)
        FreeCredentialsHandle(&identity->credential);
    if (identity->certificate)
        CertFreeCertificateContext(identity->certificate);
    if (identity->store) CertCloseStore(identity->store, 0);
    if (identity->key) NCryptFreeObject(identity->key);
    if (identity->key_provider) NCryptFreeObject(identity->key_provider);
    free(identity);
}

BEANS_NET_API long long beans_tls_add_identity(long long handle,
                                               const uint8_t* blob,
                                               const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->is_server || !blob || !req || s->context_valid)
        return BEANS_NET_ERR_INVALID;
    uint64_t format = beans_net_word(req, 0);
    uint64_t name_len = beans_net_word(req, 1);
    uint64_t cert_len = beans_net_word(req, 2);
    uint64_t key_len = beans_net_word(req, 3);
    uint64_t password_len = beans_net_word(req, 4);
    if (format > 1 || name_len >= 256 || cert_len == 0 ||
        (format == 0 && key_len == 0) || name_len > SIZE_MAX ||
        cert_len > SIZE_MAX || key_len > SIZE_MAX || password_len > SIZE_MAX)
        return BEANS_NET_ERR_INVALID;
    size_t total = (size_t)name_len;
    if ((size_t)cert_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    total += (size_t)cert_len;
    if ((size_t)key_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    total += (size_t)key_len;
    if ((size_t)password_len > SIZE_MAX - total) return BEANS_NET_ERR_RANGE;
    for (size_t i = 0; i < (size_t)name_len; i++)
        if (blob[i] == 0 || blob[i] > 127) return BEANS_NET_ERR_INVALID;
    beans_tls_schannel_identity* entry =
        (beans_tls_schannel_identity*)calloc(1, sizeof(*entry));
    if (!entry) return BEANS_NET_ERR_MEMORY;
    memcpy(entry->name, blob, (size_t)name_len);
    entry->name[name_len] = 0;
    for (beans_tls_schannel_identity* at = s->identities; at; at = at->next) {
        if (_stricmp(at->name, entry->name) == 0) {
            free(entry);
            return BEANS_NET_ERR_INVALID;
        }
    }
    const uint8_t* cert = blob + name_len;
    const uint8_t* key = cert + cert_len;
    const uint8_t* password = key + key_len;
    int loaded = format == 0
        ? beans_tls_win_pem_identity(
            entry, cert, (size_t)cert_len, key, (size_t)key_len,
            password, (size_t)password_len)
        : beans_tls_win_pfx_identity(
            entry, cert, (size_t)cert_len,
            password, (size_t)password_len);
    if (!loaded || !beans_tls_win_acquire_server(entry)) {
        beans_tls_win_free_identity(entry);
        return BEANS_NET_ERR_INVALID;
    }
    entry->next = s->identities;
    s->identities = entry;
    if (name_len == 0) s->default_identity = entry;
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_feed(long long handle, const uint8_t* data,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    if (len == 0) return BEANS_TLS_OK;
    if (!data || len > SIZE_MAX) return BEANS_NET_ERR_INVALID;
    return beans_tls_buf_push(&s->incoming, data, (size_t)len)
        ? BEANS_TLS_OK : BEANS_TLS_PROTOCOL;
}

BEANS_NET_API long long beans_tls_outgoing_size(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    return s ? (long long)beans_tls_buf_available(&s->outgoing) : -1;
}

BEANS_NET_API long long beans_tls_pull_outgoing(long long handle, uint8_t* out,
                                                const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req) return -1;
    uint64_t cap = beans_net_word(req, 0);
    if (cap > SIZE_MAX) cap = SIZE_MAX;
    return (long long)beans_tls_buf_take(&s->outgoing, out, (size_t)cap);
}

// Extracts SNI from the first ClientHello without consuming it. SChannel's
// server credential must be selected before AcceptSecurityContext sees that
// hello, so this small bounded parser only handles the identity lookup; SSPI
// still parses and authenticates the actual handshake.
static int beans_tls_win_client_name(beans_tls_session* s,
                                     char name[256]) {
    const uint8_t* input = s->incoming.data + s->incoming.head;
    size_t input_len = beans_tls_buf_available(&s->incoming);
    uint8_t* hello = NULL;
    size_t hello_len = 0, wanted = 0, record_at = 0;
    while (record_at < input_len) {
        if (input_len - record_at < 5) { free(hello); return 0; }
        if (input[record_at] != 22) { free(hello); return -1; }
        size_t record_len = ((size_t)input[record_at + 3] << 8) |
                            input[record_at + 4];
        if (record_len == 0 || record_len > 18432) {
            free(hello); return -1;
        }
        if (input_len - record_at - 5 < record_len) {
            free(hello); return 0;
        }
        if (hello_len > 65536 - record_len) { free(hello); return -1; }
        uint8_t* grown = (uint8_t*)realloc(hello, hello_len + record_len);
        if (!grown) { free(hello); return -1; }
        hello = grown;
        memcpy(hello + hello_len, input + record_at + 5, record_len);
        hello_len += record_len;
        record_at += 5 + record_len;
        if (hello_len >= 4 && wanted == 0) {
            if (hello[0] != 1) { free(hello); return -1; }
            wanted = 4 + ((size_t)hello[1] << 16) +
                     ((size_t)hello[2] << 8) + hello[3];
            if (wanted < 4 || wanted > 65536) { free(hello); return -1; }
        }
        if (wanted && hello_len >= wanted) break;
    }
    if (!wanted || hello_len < wanted) { free(hello); return 0; }
    size_t at = 4;
    if (wanted - at < 34) { free(hello); return -1; }
    at += 34; // legacy version + random
    if (at >= wanted || hello[at] > wanted - at - 1) {
        free(hello); return -1;
    }
    at += 1 + hello[at];
    if (wanted - at < 2) { free(hello); return -1; }
    size_t cipher_len = ((size_t)hello[at] << 8) | hello[at + 1];
    at += 2;
    if (cipher_len > wanted - at) { free(hello); return -1; }
    at += cipher_len;
    if (at >= wanted || hello[at] > wanted - at - 1) {
        free(hello); return -1;
    }
    at += 1 + hello[at];
    name[0] = 0;
    if (wanted - at < 2) { free(hello); return 1; }
    size_t extensions_len = ((size_t)hello[at] << 8) | hello[at + 1];
    at += 2;
    if (extensions_len > wanted - at) { free(hello); return -1; }
    size_t extensions_end = at + extensions_len;
    while (extensions_end - at >= 4) {
        unsigned int type = ((unsigned int)hello[at] << 8) | hello[at + 1];
        size_t ext_len = ((size_t)hello[at + 2] << 8) | hello[at + 3];
        at += 4;
        if (ext_len > extensions_end - at) { free(hello); return -1; }
        if (type == 0) {
            if (ext_len < 5) { free(hello); return -1; }
            size_t list_len = ((size_t)hello[at] << 8) | hello[at + 1];
            if (list_len + 2 != ext_len || hello[at + 2] != 0) {
                free(hello); return -1;
            }
            size_t host_len = ((size_t)hello[at + 3] << 8) | hello[at + 4];
            if (host_len == 0 || host_len >= 256 || host_len + 5 > ext_len) {
                free(hello); return -1;
            }
            for (size_t i = 0; i < host_len; i++) {
                unsigned char c = hello[at + 5 + i];
                if (c == 0 || c > 127) { free(hello); return -1; }
                name[i] = (char)c;
            }
            name[host_len] = 0;
            free(hello);
            return 1;
        }
        at += ext_len;
    }
    free(hello);
    return at == extensions_end ? 1 : -1;
}

static int beans_tls_win_select_identity(beans_tls_session* s) {
    if (s->selected_identity) return 1;
    if (!s->default_identity) return -1;
    char requested[256];
    int parsed = beans_tls_win_client_name(s, requested);
    if (parsed <= 0) return parsed;
    s->selected_identity = s->default_identity;
    if (requested[0]) {
        for (beans_tls_schannel_identity* at = s->identities;
             at; at = at->next) {
            if (at->name[0] && _stricmp(at->name, requested) == 0) {
                s->selected_identity = at;
                break;
            }
        }
    }
    return 1;
}

static SecBuffer* beans_tls_win_alpn_buffer(
        beans_tls_session* s, uint8_t storage[512], SecBuffer* buffer) {
    if (s->alpn_wire_len == 0) return NULL;
    SEC_APPLICATION_PROTOCOLS* protocols =
        (SEC_APPLICATION_PROTOCOLS*)storage;
    SEC_APPLICATION_PROTOCOL_LIST* list = protocols->ProtocolLists;
    size_t list_header = offsetof(
        SEC_APPLICATION_PROTOCOL_LIST, ProtocolList);
    protocols->ProtocolListsSize =
        (ULONG)(list_header + s->alpn_wire_len);
    list->ProtoNegoExt = SecApplicationProtocolNegotiationExt_ALPN;
    list->ProtocolListSize = (USHORT)s->alpn_wire_len;
    memcpy(list->ProtocolList, s->alpn_wire, s->alpn_wire_len);
    buffer->BufferType = SECBUFFER_APPLICATION_PROTOCOLS;
    buffer->cbBuffer = (ULONG)(offsetof(
        SEC_APPLICATION_PROTOCOLS, ProtocolLists) +
        protocols->ProtocolListsSize);
    buffer->pvBuffer = protocols;
    return buffer;
}

static int beans_tls_win_append_output(beans_tls_session* s,
                                       SecBuffer* output) {
    int ok = 1;
    if (output->pvBuffer && output->cbBuffer)
        ok = beans_tls_buf_push(&s->outgoing,
            (const uint8_t*)output->pvBuffer, output->cbBuffer);
    if (output->pvBuffer) FreeContextBuffer(output->pvBuffer);
    return ok;
}

static void beans_tls_win_consume_input(beans_tls_session* s,
                                        SecBuffer* input, int count,
                                        SECURITY_STATUS status,
                                        size_t offered) {
    if (status == SEC_E_INCOMPLETE_MESSAGE) return;
    size_t extra = 0;
    for (int i = 0; i < count; i++)
        if (input[i].BufferType == SECBUFFER_EXTRA)
            extra = input[i].cbBuffer;
    if (extra > offered) extra = offered;
    beans_tls_buf_discard(&s->incoming, offered - extra);
}

static int beans_tls_win_verify_engine(PCCERT_CONTEXT peer,
                                       HCERTCHAINENGINE engine,
                                       HCERTSTORE additional,
                                       const wchar_t* host) {
    CERT_CHAIN_PARA chain_parameters;
    memset(&chain_parameters, 0, sizeof chain_parameters);
    chain_parameters.cbSize = sizeof chain_parameters;
    PCCERT_CHAIN_CONTEXT chain = NULL;
    if (!CertGetCertificateChain(engine, peer, NULL, additional,
            &chain_parameters, 0, NULL, &chain)) return 0;
    SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl;
    memset(&ssl, 0, sizeof ssl);
    ssl.cbSize = sizeof ssl;
    ssl.dwAuthType = AUTHTYPE_SERVER;
    ssl.pwszServerName = (wchar_t*)host;
    CERT_CHAIN_POLICY_PARA policy;
    CERT_CHAIN_POLICY_STATUS result;
    memset(&policy, 0, sizeof policy);
    memset(&result, 0, sizeof result);
    policy.cbSize = sizeof policy;
    policy.pvExtraPolicyPara = &ssl;
    result.cbSize = sizeof result;
    int ok = CertVerifyCertificateChainPolicy(
        CERT_CHAIN_POLICY_SSL, chain, &policy, &result) &&
        result.dwError == 0;
    CertFreeCertificateChain(chain);
    return ok;
}

static int beans_tls_win_verify(beans_tls_session* s) {
    PCCERT_CONTEXT peer = NULL;
    if (QueryContextAttributesW(&s->context,
            SECPKG_ATTR_REMOTE_CERT_CONTEXT, &peer) != SEC_E_OK || !peer)
        return 0;
    int ok = beans_tls_win_verify_engine(
        peer, NULL, s->extra_roots, s->host);
    if (!ok && s->extra_roots) {
        CERT_CHAIN_ENGINE_CONFIG config;
        memset(&config, 0, sizeof config);
        config.cbSize = sizeof config;
        config.hExclusiveRoot = s->extra_roots;
        HCERTCHAINENGINE engine = NULL;
        if (CertCreateCertificateChainEngine(&config, &engine)) {
            ok = beans_tls_win_verify_engine(
                peer, engine, s->extra_roots, s->host);
            CertFreeCertificateChainEngine(engine);
        }
    }
    CertFreeCertificateContext(peer);
    return ok;
}

BEANS_NET_API long long beans_tls_handshake(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->handshake_done) return BEANS_TLS_OK;
    if (s->is_server && !s->context_valid) {
        int selected = beans_tls_win_select_identity(s);
        if (selected == 0) return BEANS_TLS_WANT_IO;
        if (selected < 0) return BEANS_TLS_HANDSHAKE;
    }
    size_t offered = beans_tls_buf_available(&s->incoming);
    SecBuffer input[2];
    memset(input, 0, sizeof input);
    int input_count = 0;
    if (offered > 0) {
        input[input_count].BufferType = SECBUFFER_TOKEN;
        input[input_count].cbBuffer = offered > ULONG_MAX
            ? ULONG_MAX : (ULONG)offered;
        offered = input[input_count].cbBuffer;
        input[input_count].pvBuffer = s->incoming.data + s->incoming.head;
        input_count++;
    } else if (s->is_server) {
        return BEANS_TLS_WANT_IO;
    }
    uint8_t protocol_storage[512];
    if (!s->context_valid && s->alpn_wire_len > 0)
        if (beans_tls_win_alpn_buffer(
                s, protocol_storage, &input[input_count])) input_count++;
    SecBufferDesc input_desc;
    input_desc.ulVersion = SECBUFFER_VERSION;
    input_desc.cBuffers = (ULONG)input_count;
    input_desc.pBuffers = input;
    SecBuffer output;
    memset(&output, 0, sizeof output);
    output.BufferType = SECBUFFER_TOKEN;
    SecBufferDesc output_desc;
    output_desc.ulVersion = SECBUFFER_VERSION;
    output_desc.cBuffers = 1;
    output_desc.pBuffers = &output;
    ULONG attributes = 0;
    TimeStamp expiry;
    SECURITY_STATUS status;
    if (s->is_server) {
        ULONG flags = ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT |
                      ASC_REQ_CONFIDENTIALITY | ASC_REQ_EXTENDED_ERROR |
                      ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM;
        status = AcceptSecurityContext(
            &s->selected_identity->credential,
            s->context_valid ? &s->context : NULL,
            input_count ? &input_desc : NULL, flags,
            SECURITY_NATIVE_DREP, &s->context,
            &output_desc, &attributes, &expiry);
    } else {
        ULONG flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT |
                      ISC_REQ_CONFIDENTIALITY | ISC_REQ_EXTENDED_ERROR |
                      ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
        status = InitializeSecurityContextW(
            &s->credential, s->context_valid ? &s->context : NULL,
            s->host, flags, 0, SECURITY_NATIVE_DREP,
            input_count ? &input_desc : NULL, 0, &s->context,
            &output_desc, &attributes, &expiry);
    }
    if (status == SEC_E_OK || status == SEC_I_CONTINUE_NEEDED)
        s->context_valid = 1;
    beans_tls_win_consume_input(
        s, input, input_count, status, offered);
    if (!beans_tls_win_append_output(s, &output)) return BEANS_TLS_PROTOCOL;
    if (status == SEC_E_OK) {
        if (!s->is_server && !beans_tls_win_verify(s))
            return BEANS_TLS_HANDSHAKE;
        if (QueryContextAttributesW(&s->context,
                SECPKG_ATTR_STREAM_SIZES, &s->sizes) != SEC_E_OK)
            return BEANS_TLS_HANDSHAKE;
        s->handshake_done = 1;
        s->verified = 1;
        return BEANS_TLS_OK;
    }
    if (status == SEC_I_CONTINUE_NEEDED ||
        status == SEC_E_INCOMPLETE_MESSAGE)
        return BEANS_TLS_WANT_IO;
    return BEANS_TLS_HANDSHAKE;
}

BEANS_NET_API long long beans_tls_alpn(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req || !s->context_valid) return 0;
    SecPkgContext_ApplicationProtocol protocol;
    memset(&protocol, 0, sizeof protocol);
    if (QueryContextAttributesW(&s->context,
            SECPKG_ATTR_APPLICATION_PROTOCOL, &protocol) != SEC_E_OK ||
        protocol.ProtoNegoStatus !=
            SecApplicationProtocolNegotiationStatus_Success ||
        protocol.ProtocolIdSize == 0 ||
        protocol.ProtocolIdSize > beans_net_word(req, 0)) return 0;
    memcpy(out, protocol.ProtocolId, protocol.ProtocolIdSize);
    return protocol.ProtocolIdSize;
}

BEANS_NET_API long long beans_tls_write(long long handle, const uint8_t* data,
                                        const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !req) return BEANS_TLS_R_INVALID;
    uint64_t raw_len = beans_net_word(req, 0);
    if (raw_len == 0) return 0;
    if (!data || !s->handshake_done || s->close_sent)
        return BEANS_TLS_R_INVALID;
    size_t len = (size_t)raw_len;
    if (raw_len > SIZE_MAX) len = SIZE_MAX;
    if (len > s->sizes.cbMaximumMessage) len = s->sizes.cbMaximumMessage;
    if (len > ULONG_MAX) len = ULONG_MAX;
    size_t total = (size_t)s->sizes.cbHeader + len + s->sizes.cbTrailer;
    uint8_t* record = (uint8_t*)malloc(total);
    if (!record) return BEANS_TLS_R_PROTOCOL;
    memcpy(record + s->sizes.cbHeader, data, len);
    SecBuffer buffers[4];
    memset(buffers, 0, sizeof buffers);
    buffers[0].BufferType = SECBUFFER_STREAM_HEADER;
    buffers[0].pvBuffer = record;
    buffers[0].cbBuffer = s->sizes.cbHeader;
    buffers[1].BufferType = SECBUFFER_DATA;
    buffers[1].pvBuffer = record + s->sizes.cbHeader;
    buffers[1].cbBuffer = (ULONG)len;
    buffers[2].BufferType = SECBUFFER_STREAM_TRAILER;
    buffers[2].pvBuffer = record + s->sizes.cbHeader + len;
    buffers[2].cbBuffer = s->sizes.cbTrailer;
    buffers[3].BufferType = SECBUFFER_EMPTY;
    SecBufferDesc desc = { SECBUFFER_VERSION, 4, buffers };
    SECURITY_STATUS status = EncryptMessage(&s->context, 0, &desc, 0);
    int pushed = status == SEC_E_OK &&
        beans_tls_buf_push(&s->outgoing,
            (const uint8_t*)buffers[0].pvBuffer, buffers[0].cbBuffer) &&
        beans_tls_buf_push(&s->outgoing,
            (const uint8_t*)buffers[1].pvBuffer, buffers[1].cbBuffer) &&
        beans_tls_buf_push(&s->outgoing,
            (const uint8_t*)buffers[2].pvBuffer, buffers[2].cbBuffer);
    free(record);
    return pushed ? (long long)len : BEANS_TLS_R_PROTOCOL;
}

BEANS_NET_API long long beans_tls_read(long long handle, uint8_t* out,
                                       const uint64_t* req) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !out || !req || !s->handshake_done)
        return BEANS_TLS_R_INVALID;
    uint64_t raw_cap = beans_net_word(req, 0);
    if (raw_cap > SIZE_MAX) raw_cap = SIZE_MAX;
    size_t cap = (size_t)raw_cap;
    size_t ready = beans_tls_buf_available(&s->plaintext);
    if (ready > 0)
        return (long long)beans_tls_buf_take(&s->plaintext, out, cap);
    size_t offered = beans_tls_buf_available(&s->incoming);
    if (offered == 0) return s->closed
        ? BEANS_TLS_R_CLOSED : BEANS_TLS_R_WANT_IO;
    if (offered > ULONG_MAX) offered = ULONG_MAX;
    SecBuffer buffers[4];
    memset(buffers, 0, sizeof buffers);
    buffers[0].BufferType = SECBUFFER_DATA;
    buffers[0].pvBuffer = s->incoming.data + s->incoming.head;
    buffers[0].cbBuffer = (ULONG)offered;
    for (int i = 1; i < 4; i++) buffers[i].BufferType = SECBUFFER_EMPTY;
    SecBufferDesc desc = { SECBUFFER_VERSION, 4, buffers };
    SECURITY_STATUS status = DecryptMessage(&s->context, &desc, 0, NULL);
    if (status == SEC_E_INCOMPLETE_MESSAGE) return BEANS_TLS_R_WANT_IO;
    size_t extra = 0;
    int pushed = 1;
    for (int i = 0; i < 4; i++) {
        if (buffers[i].BufferType == SECBUFFER_EXTRA)
            extra = buffers[i].cbBuffer;
        if (buffers[i].BufferType == SECBUFFER_DATA && buffers[i].cbBuffer)
            pushed = pushed && beans_tls_buf_push(
                &s->plaintext, (const uint8_t*)buffers[i].pvBuffer,
                buffers[i].cbBuffer);
    }
    if (extra > offered) extra = offered;
    beans_tls_buf_discard(&s->incoming, offered - extra);
    if (!pushed) return BEANS_TLS_R_PROTOCOL;
    if (status == SEC_I_CONTEXT_EXPIRED) s->closed = 1;
    else if (status == SEC_I_RENEGOTIATE) return BEANS_TLS_R_PROTOCOL;
    else if (status != SEC_E_OK) return BEANS_TLS_R_PROTOCOL;
    ready = beans_tls_buf_available(&s->plaintext);
    if (ready > 0)
        return (long long)beans_tls_buf_take(&s->plaintext, out, cap);
    return s->closed ? BEANS_TLS_R_CLOSED : BEANS_TLS_R_WANT_IO;
}

BEANS_NET_API long long beans_tls_close_notify(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s || !s->context_valid) return BEANS_NET_ERR_INVALID;
    if (s->close_sent) return BEANS_TLS_OK;
    DWORD shutdown = SCHANNEL_SHUTDOWN;
    SecBuffer control = { sizeof shutdown, SECBUFFER_TOKEN, &shutdown };
    SecBufferDesc control_desc = { SECBUFFER_VERSION, 1, &control };
    if (ApplyControlToken(&s->context, &control_desc) != SEC_E_OK)
        return BEANS_TLS_PROTOCOL;
    SecBuffer output;
    memset(&output, 0, sizeof output);
    output.BufferType = SECBUFFER_TOKEN;
    SecBufferDesc output_desc = { SECBUFFER_VERSION, 1, &output };
    ULONG attributes = 0;
    TimeStamp expiry;
    SECURITY_STATUS status;
    if (s->is_server) {
        ULONG flags = ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT |
                      ASC_REQ_CONFIDENTIALITY | ASC_REQ_EXTENDED_ERROR |
                      ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM;
        status = AcceptSecurityContext(
            &s->selected_identity->credential, &s->context, NULL,
            flags, SECURITY_NATIVE_DREP, &s->context,
            &output_desc, &attributes, &expiry);
    } else {
        ULONG flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT |
                      ISC_REQ_CONFIDENTIALITY | ISC_REQ_EXTENDED_ERROR |
                      ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
        status = InitializeSecurityContextW(
            &s->credential, &s->context, s->host, flags, 0,
            SECURITY_NATIVE_DREP, NULL, 0, &s->context,
            &output_desc, &attributes, &expiry);
    }
    int output_ok = beans_tls_win_append_output(s, &output);
    if (!output_ok || (status != SEC_E_OK &&
                       status != SEC_I_CONTINUE_NEEDED))
        return BEANS_TLS_PROTOCOL;
    s->close_sent = 1;
    return BEANS_TLS_OK;
}

BEANS_NET_API long long beans_tls_free(long long handle) {
    beans_tls_session* s = beans_tls_of(handle);
    if (!s) return BEANS_NET_ERR_INVALID;
    if (s->context_valid) DeleteSecurityContext(&s->context);
    if (s->credential_valid) FreeCredentialsHandle(&s->credential);
    if (s->extra_roots) CertCloseStore(s->extra_roots, 0);
    beans_tls_schannel_identity* identity = s->identities;
    while (identity) {
        beans_tls_schannel_identity* next = identity->next;
        beans_tls_win_free_identity(identity);
        identity = next;
    }
    free(s->incoming.data);
    free(s->outgoing.data);
    free(s->plaintext.data);
    s->magic = 0;
    free(s);
    return BEANS_NET_OK;
}

BEANS_NET_API long long beans_tls_available(void) { return 1; }
#endif

// Network.framework is the only public macOS TLS API that can negotiate
// server ALPN. Other targets build the same symbols so the C/Beans surface is
// exact, but std.tls uses the portable accepted-socket byte pump there.
#if !defined(__APPLE__)
BEANS_NET_API long long beans_tls_listener_start(long long handle,
                                                 const uint8_t* host,
                                                 const uint64_t* req) {
    (void)handle; (void)host; (void)req;
    return BEANS_NET_ERR_UNSUPPORTED;
}
BEANS_NET_API long long beans_tls_listener_port(long long handle) {
    (void)handle;
    return -1;
}
BEANS_NET_API long long beans_tls_listener_accept(long long handle,
                                                  const uint64_t* req) {
    (void)handle; (void)req;
    return BEANS_TLS_R_UNSUPPORTED;
}
BEANS_NET_API long long beans_tls_nw_read(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    (void)handle; (void)out; (void)req;
    return BEANS_TLS_R_UNSUPPORTED;
}
BEANS_NET_API long long beans_tls_nw_write(long long handle,
                                           const uint8_t* data,
                                           const uint64_t* req) {
    (void)handle; (void)data; (void)req;
    return BEANS_TLS_R_UNSUPPORTED;
}
BEANS_NET_API long long beans_tls_nw_alpn(long long handle, uint8_t* out,
                                          const uint64_t* req) {
    (void)handle; (void)out; (void)req;
    return -1;
}
BEANS_NET_API long long beans_tls_nw_shutdown(long long handle,
                                              const uint64_t* req) {
    (void)handle; (void)req;
    return BEANS_NET_ERR_UNSUPPORTED;
}
BEANS_NET_API long long beans_tls_nw_free(long long handle) {
    (void)handle;
    return BEANS_NET_ERR_UNSUPPORTED;
}
#endif
