// Drives the OpenSSL lane of the TLS bridge directly, so the second backend
// is exercised on any host with a libssl — including macOS, where the
// shipped backend is SecureTransport and would otherwise be the only one
// ever tested. Compiled with -U__APPLE__ so beans_net_tls.c takes its
// POSIX/dlopen path; BEANS_LIBSSL names the library.
//
//   tls_openssl_probe <ca.pem> <host> <port> [alpn] [connect-address]
//
// Prints one line: "accepted alpn=<proto>" or "rejected <reason>", matching
// the verdict vocabulary test/cases/tls_verify.b prints, so test/tls.sh can
// hold both backends to the same table.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <netdb.h>
#include <sys/socket.h>

extern long long beans_tls_client_new(const uint8_t*, const uint8_t*, const uint64_t*);
extern long long beans_tls_add_root(long long, const uint8_t*, const uint64_t*);
extern long long beans_tls_feed(long long, const uint8_t*, const uint64_t*);
extern long long beans_tls_outgoing_size(long long);
extern long long beans_tls_pull_outgoing(long long, uint8_t*, const uint64_t*);
extern long long beans_tls_handshake(long long);
extern long long beans_tls_alpn(long long, uint8_t*, const uint64_t*);
extern long long beans_tls_free(long long);
extern long long beans_tls_available(void);

static int dial(const char* host, const char* port) {
    struct addrinfo hints, *list = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &list) != 0) return -1;
    int fd = -1;
    for (struct addrinfo* ai = list; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(list);
    return fd;
}

static int flush_out(long long handle, int fd) {
    for (;;) {
        long long pending = beans_tls_outgoing_size(handle);
        if (pending <= 0) return 0;
        uint8_t buf[16384];
        uint64_t req[1] = { sizeof buf };
        long long got = beans_tls_pull_outgoing(handle, buf, req);
        if (got <= 0) return 0;
        ssize_t sent = 0;
        while (sent < got) {
            ssize_t n = write(fd, buf + sent, (size_t)(got - sent));
            if (n <= 0) return -1;
            sent += n;
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 4) { printf("rejected usage\n"); return 2; }
    const char* ca_path = argv[1];
    const char* host = argv[2];
    const char* port = argv[3];
    const char* alpn = argc > 4 ? argv[4] : "";
    const char* address = argc > 5 ? argv[5] : host;

    if (!beans_tls_available()) { printf("rejected unsupported\n"); return 0; }

    FILE* f = fopen(ca_path, "rb");
    if (!f) { printf("rejected no-ca\n"); return 2; }
    static char pem[65536];
    size_t pem_len = fread(pem, 1, sizeof pem, f);
    fclose(f);

    int fd = dial(address, port);
    if (fd < 0) { printf("rejected refused\n"); return 0; }

    uint64_t req[3] = { 0, strlen(host), strlen(alpn) };
    long long handle = beans_tls_client_new(
        (const uint8_t*)host, alpn[0] ? (const uint8_t*)alpn : NULL, req);
    if (!handle) { printf("rejected unsupported\n"); close(fd); return 0; }

    uint64_t root_req[1] = { pem_len };
    if (beans_tls_add_root(handle, (const uint8_t*)pem, root_req) != 0) {
        printf("rejected bad-root\n");
        beans_tls_free(handle);
        close(fd);
        return 0;
    }

    int verdict_done = 0;
    for (int rounds = 0; rounds < 200 && !verdict_done; rounds++) {
        long long status = beans_tls_handshake(handle);
        if (flush_out(handle, fd) != 0) { printf("rejected write\n"); verdict_done = 1; break; }
        if (status == 0) {
            uint8_t proto[64];
            uint64_t preq[1] = { sizeof proto };
            long long plen = beans_tls_alpn(handle, proto, preq);
            printf("accepted alpn=%.*s\n", plen > 0 ? (int)plen : 0, (char*)proto);
            verdict_done = 1;
            break;
        }
        if (status != 114) { printf("rejected handshake\n"); verdict_done = 1; break; }
        uint8_t in[16384];
        ssize_t n = read(fd, in, sizeof in);
        if (n <= 0) { printf("rejected handshake\n"); verdict_done = 1; break; }
        uint64_t feed_req[1] = { (uint64_t)n };
        if (beans_tls_feed(handle, in, feed_req) != 0) {
            printf("rejected protocol\n");
            verdict_done = 1;
            break;
        }
    }
    if (!verdict_done) printf("rejected stalled\n");
    beans_tls_free(handle);
    close(fd);
    return 0;
}
