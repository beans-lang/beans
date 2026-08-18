// Runs the OpenSSL side of the TLS bridge as a server. This lets the TLS
// suite test that backend on macOS too, where normal Beans programs use
// SecureTransport. It accepts one SNI/PEM client and one PKCS#12 client.
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern long long beans_tls_client_new(const uint8_t*, const uint8_t*,
                                      const uint64_t*);
extern long long beans_tls_add_identity(long long, const uint8_t*,
                                        const uint64_t*);
extern long long beans_tls_feed(long long, const uint8_t*, const uint64_t*);
extern long long beans_tls_outgoing_size(long long);
extern long long beans_tls_pull_outgoing(long long, uint8_t*, const uint64_t*);
extern long long beans_tls_handshake(long long);
extern long long beans_tls_alpn(long long, uint8_t*, const uint64_t*);
extern long long beans_tls_write(long long, const uint8_t*, const uint64_t*);
extern long long beans_tls_read(long long, uint8_t*, const uint64_t*);
extern long long beans_tls_close_notify(long long);
extern long long beans_tls_free(long long);
extern long long beans_tls_available(void);

typedef struct {
    uint8_t* data;
    size_t len;
} blob;

static blob load(const char* path) {
    blob result = { NULL, 0 };
    FILE* file = fopen(path, "rb");
    if (!file || fseek(file, 0, SEEK_END) != 0) goto done;
    long size = ftell(file);
    if (size <= 0 || size > 16 * 1024 * 1024 ||
        fseek(file, 0, SEEK_SET) != 0) goto done;
    result.data = (uint8_t*)malloc((size_t)size);
    if (!result.data) goto done;
    result.len = fread(result.data, 1, (size_t)size, file);
    if (result.len != (size_t)size) {
        free(result.data);
        result.data = NULL;
        result.len = 0;
    }
done:
    if (file) fclose(file);
    return result;
}

static int flush_out(long long handle, int fd) {
    for (;;) {
        long long pending = beans_tls_outgoing_size(handle);
        if (pending < 0) return 0;
        if (pending == 0) return 1;
        uint8_t out[16384];
        uint64_t req[1] = { sizeof out };
        long long got = beans_tls_pull_outgoing(handle, out, req);
        if (got <= 0) return 0;
        size_t sent = 0;
        while (sent < (size_t)got) {
            ssize_t n = write(fd, out + sent, (size_t)got - sent);
            if (n <= 0) return 0;
            sent += (size_t)n;
        }
    }
}

static int feed_more(long long handle, int fd) {
    uint8_t input[16384];
    ssize_t got = read(fd, input, sizeof input);
    if (got <= 0) return 0;
    uint64_t req[1] = { (uint64_t)got };
    return beans_tls_feed(handle, input, req) == 0;
}

static int add_identity(long long handle, int format, const char* name,
                        blob cert, blob key, const char* password) {
    size_t name_len = strlen(name);
    size_t password_len = strlen(password);
    if (name_len > SIZE_MAX - cert.len ||
        name_len + cert.len > SIZE_MAX - key.len ||
        name_len + cert.len + key.len > SIZE_MAX - password_len)
        return 0;
    size_t len = name_len + cert.len + key.len + password_len;
    uint8_t* joined = (uint8_t*)malloc(len ? len : 1);
    if (!joined) return 0;
    size_t at = 0;
    memcpy(joined + at, name, name_len); at += name_len;
    memcpy(joined + at, cert.data, cert.len); at += cert.len;
    memcpy(joined + at, key.data, key.len); at += key.len;
    memcpy(joined + at, password, password_len);
    uint64_t req[5] = {
        (uint64_t)format, (uint64_t)name_len, (uint64_t)cert.len,
        (uint64_t)key.len, (uint64_t)password_len
    };
    int ok = beans_tls_add_identity(handle, joined, req) == 0;
    free(joined);
    return ok;
}

static int serve(int fd, blob cert, blob key, blob named_cert, blob named_key,
                 blob p12, int use_p12, const char* expected_alpn) {
    const char* alpn = "h2,http/1.1";
    uint64_t new_req[3] = { 1, 0, strlen(alpn) };
    long long handle = beans_tls_client_new(
        NULL, (const uint8_t*)alpn, new_req);
    if (!handle) return 0;
    int good = use_p12
        ? add_identity(handle, 1, "", p12, (blob){NULL, 0}, "beans")
        : add_identity(handle, 0, "", cert, key, "") &&
          add_identity(handle, 0, "sni.localhost", named_cert, named_key, "");
    for (int rounds = 0; good && rounds < 200; rounds++) {
        long long status = beans_tls_handshake(handle);
        good = flush_out(handle, fd);
        if (!good || status == 0) break;
        if (status != 114 || !feed_more(handle, fd)) { good = 0; break; }
    }
    if (good) {
        uint8_t selected[64];
        uint64_t req[1] = { sizeof selected };
        long long n = beans_tls_alpn(handle, selected, req);
        good = n == (long long)strlen(expected_alpn) &&
               memcmp(selected, expected_alpn, (size_t)n) == 0;
    }
    uint8_t request[4];
    size_t have = 0;
    for (int rounds = 0; good && have < sizeof request && rounds < 200; rounds++) {
        uint64_t req[1] = { sizeof request - have };
        long long n = beans_tls_read(handle, request + have, req);
        if (n > 0) have += (size_t)n;
        else if ((n == -1 || n == -7) && feed_more(handle, fd)) {}
        else good = 0;
        if (good) good = flush_out(handle, fd);
    }
    good = good && have == sizeof request &&
           memcmp(request, "ping", sizeof request) == 0;
    size_t sent = 0;
    while (good && sent < 4) {
        uint64_t req[1] = { 4 - sent };
        long long n = beans_tls_write(
            handle, (const uint8_t*)"pong" + sent, req);
        if (n > 0) sent += (size_t)n;
        else if (n != -1 && n != -7) good = 0;
        if (good) good = flush_out(handle, fd);
    }
    if (good) {
        good = beans_tls_close_notify(handle) == 0 && flush_out(handle, fd);
    }
    beans_tls_free(handle);
    close(fd);
    return good;
}

int main(int argc, char** argv) {
    if (argc != 7 || !beans_tls_available()) return 2;
    blob cert = load(argv[1]);
    blob key = load(argv[2]);
    blob named_cert = load(argv[3]);
    blob named_key = load(argv[4]);
    blob p12 = load(argv[5]);
    if (!cert.data || !key.data || !named_cert.data || !named_key.data ||
        !p12.data) return 2;
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((uint16_t)atoi(argv[6]));
    if (listener < 0 || bind(listener, (struct sockaddr*)&address,
                             sizeof address) != 0 ||
        listen(listener, 2) != 0) return 2;
    fprintf(stderr, "listening\n");
    int first = accept(listener, NULL, NULL);
    int pem_ok = first >= 0 && serve(
        first, cert, key, named_cert, named_key, p12, 0, "h2");
    int second = accept(listener, NULL, NULL);
    int p12_ok = second >= 0 && serve(
        second, cert, key, named_cert, named_key, p12, 1, "http/1.1");
    close(listener);
    printf("openssl tls server pem sni alpn %s\n", pem_ok ? "true" : "false");
    printf("openssl tls server pkcs12 alpn %s\n", p12_ok ? "true" : "false");
    free(cert.data); free(key.data); free(named_cert.data);
    free(named_key.data); free(p12.data);
    return pem_ok && p12_ok ? 0 : 1;
}
