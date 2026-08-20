// Socket extras for std.net — the operations too specialized for the core
// syscall layer in beans_rt.c but still part of the socket contract. This
// file owns multicast membership, reusable listener creation, and reads into
// caller-owned storage.
//
// Operations on existing descriptors never take ownership. Listener creation
// returns a new descriptor to the Beans side. Statuses follow
// beans_net_common.h; operation-specific statuses start above 100.

#include "beans_net_common.h"
#include <stdio.h>

#if defined(_WIN32)
  #include <winsock2.h>
  #include <ws2tcpip.h>
#else
  #include <sys/types.h>
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <netdb.h>
  #include <fcntl.h>
  #include <unistd.h>
  #include <errno.h>
#endif

static int beans_sockx_os_error(void) {
#if defined(_WIN32)
    return (int)WSAGetLastError();
#else
    return errno;
#endif
}

enum {
    BEANS_SOCKX_ERR_TIMEOUT = 110,
    BEANS_SOCKX_ERR_RESET = 111,
    BEANS_SOCKX_ERR_CLOSED = 112,
    BEANS_SOCKX_ERR_IN_USE = 113,
    BEANS_SOCKX_ERR_PERMISSION = 114,
    BEANS_SOCKX_ERR_NOT_FOUND = 115,
    BEANS_SOCKX_ERR_IO = 116,
};

static int beans_sockx_error_status(int error) {
#if defined(_WIN32)
    if (error == WSAEWOULDBLOCK || error == WSAETIMEDOUT)
        return BEANS_SOCKX_ERR_TIMEOUT;
    if (error == WSAECONNRESET || error == WSAECONNABORTED ||
        error == WSAESHUTDOWN)
        return BEANS_SOCKX_ERR_RESET;
    if (error == WSAENOTSOCK || error == WSAENOTCONN)
        return BEANS_SOCKX_ERR_CLOSED;
    if (error == WSAEADDRINUSE || error == WSAEADDRNOTAVAIL)
        return BEANS_SOCKX_ERR_IN_USE;
    if (error == WSAEACCES) return BEANS_SOCKX_ERR_PERMISSION;
#else
    if (error == EAGAIN || error == EWOULDBLOCK || error == ETIMEDOUT)
        return BEANS_SOCKX_ERR_TIMEOUT;
    if (error == ECONNRESET || error == ECONNABORTED || error == EPIPE)
        return BEANS_SOCKX_ERR_RESET;
    if (error == EBADF || error == ENOTCONN)
        return BEANS_SOCKX_ERR_CLOSED;
    if (error == EADDRINUSE || error == EADDRNOTAVAIL)
        return BEANS_SOCKX_ERR_IN_USE;
    if (error == EACCES || error == EPERM)
        return BEANS_SOCKX_ERR_PERMISSION;
#endif
    return BEANS_SOCKX_ERR_IO;
}

// Reads into an existing Beans buffer without changing its length.
//
//   req[0] in: destination size; out: bytes read (0 is EOF)
//   req[1] out: OS error code when the returned status is not OK
BEANS_NET_API long long beans_sockx_recv_into(
    long long fd, uint8_t* destination, uint64_t* req) {
    if (!req || !destination || beans_net_word(req, 0) == 0)
        return BEANS_NET_ERR_INVALID;
    uint64_t wanted = beans_net_word(req, 0);
#if defined(_WIN32)
    if (wanted > INT_MAX) wanted = INT_MAX;
    int got;
    do {
        got = recv((SOCKET)fd, (char*)destination, (int)wanted, 0);
    } while (got < 0 && WSAGetLastError() == WSAEINTR);
    if (got < 0) {
        int error = WSAGetLastError();
        req[1] = (uint64_t)error;
        return beans_sockx_error_status(error);
    }
#else
    ssize_t got;
    do {
        got = recv((int)fd, destination, (size_t)wanted, 0);
    } while (got < 0 && errno == EINTR);
    if (got < 0) {
        int error = errno;
        req[1] = (uint64_t)error;
        return beans_sockx_error_status(error);
    }
#endif
    req[0] = (uint64_t)got;
    req[1] = 0;
    return BEANS_NET_OK;
}

// Creates a TCP listener with SO_REUSEPORT set before bind. Each listener
// still has one owner; the option only lets independent accept loops bind the
// same address. Windows has no matching load-balancing contract, so it reports
// unsupported instead of using its unsafe SO_REUSEADDR semantics.
//
//   host is UTF-8 text, not NUL-terminated
//   req[0] host length, req[1] port, req[2] backlog
//   req[3] out: descriptor on success, req[4] out: OS resolver/socket error
BEANS_NET_API long long beans_sockx_listen_reuse_port(
    const uint8_t* host, uint64_t* req) {
    if (!host || !req) return BEANS_NET_ERR_INVALID;
    uint64_t host_len = beans_net_word(req, 0);
    uint64_t port = beans_net_word(req, 1);
    uint64_t backlog = beans_net_word(req, 2);
    if (host_len == 0 || host_len > 1024 || port > 65535)
        return BEANS_NET_ERR_INVALID;
#if defined(_WIN32) || !defined(SO_REUSEPORT)
    (void)backlog;
    return BEANS_NET_ERR_UNSUPPORTED;
#else
    char* text = (char*)malloc((size_t)host_len + 1);
    if (!text) return BEANS_NET_ERR_MEMORY;
    memcpy(text, host, (size_t)host_len);
    text[host_len] = 0;
    char service[16];
    snprintf(service, sizeof service, "%llu", (unsigned long long)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV;
    struct addrinfo* addresses = NULL;
    int resolved = getaddrinfo(text, service, &hints, &addresses);
    free(text);
    if (resolved != 0) {
        req[4] = (uint64_t)resolved;
        return BEANS_SOCKX_ERR_NOT_FOUND;
    }
    if (backlog < 1) backlog = 1;
    if (backlog > 1024) backlog = 1024;
    int last = 0;
    for (struct addrinfo* address = addresses;
         address; address = address->ai_next) {
        int fd;
#ifdef SOCK_CLOEXEC
        fd = socket(address->ai_family,
                    address->ai_socktype | SOCK_CLOEXEC,
                    address->ai_protocol);
        if (fd < 0 && errno == EINVAL)
#endif
        {
            fd = socket(address->ai_family, address->ai_socktype,
                        address->ai_protocol);
            if (fd >= 0) {
                int flags = fcntl(fd, F_GETFD, 0);
                if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
            }
        }
        if (fd < 0) { last = errno; continue; }
        int one = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                       &one, sizeof one) != 0 ||
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT,
                       &one, sizeof one) != 0) {
            last = errno;
            close(fd);
            continue;
        }
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        if (bind(fd, address->ai_addr, address->ai_addrlen) == 0 &&
            listen(fd, (int)backlog) == 0) {
            freeaddrinfo(addresses);
            req[3] = (uint64_t)fd;
            req[4] = 0;
            return BEANS_NET_OK;
        }
        last = errno;
        close(fd);
    }
    freeaddrinfo(addresses);
    req[4] = (uint64_t)last;
    return beans_sockx_error_status(last);
#endif
}

// Joins or leaves a multicast group on a bound UDP socket.
//
//   fd     the socket descriptor word
//   group  the group address bytes (numeric text, not NUL-terminated)
//   req    [0] group length in bytes
//          [1] 1 = join, 0 = leave
//
// Returns BEANS_NET_OK, BEANS_NET_ERR_INVALID for text that is not a
// numeric address, BEANS_NET_ERR_RANGE for an address that is not a
// multicast group, or 100+errno when the OS refuses.
BEANS_NET_API long long beans_sockx_multicast(
    long long fd, const uint8_t* group, const uint64_t* req) {
    if (!group || !req) return BEANS_NET_ERR_INVALID;
    uint64_t len = beans_net_word(req, 0);
    int join = beans_net_word(req, 1) != 0;
    if (len == 0 || len > 64) return BEANS_NET_ERR_INVALID;
    char text[80];
    memcpy(text, group, (size_t)len);
    text[len] = 0;

    struct in_addr v4;
    if (inet_pton(AF_INET, text, &v4) == 1) {
        // 224.0.0.0/4 is the whole IPv4 multicast range.
        unsigned char top = ((const unsigned char*)&v4)[0];
        if (top < 224 || top > 239) return BEANS_NET_ERR_RANGE;
        struct ip_mreq membership;
        memset(&membership, 0, sizeof membership);
        membership.imr_multiaddr = v4;
        membership.imr_interface.s_addr = INADDR_ANY;
        int option = join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP;
#if defined(_WIN32)
        if (setsockopt((SOCKET)fd, IPPROTO_IP, option,
                       (const char*)&membership, sizeof membership) != 0)
#else
        if (setsockopt((int)fd, IPPROTO_IP, option,
                       &membership, sizeof membership) != 0)
#endif
            return 100 + beans_sockx_os_error();
        return BEANS_NET_OK;
    }

    struct in6_addr v6;
    if (inet_pton(AF_INET6, text, &v6) == 1) {
        if (!IN6_IS_ADDR_MULTICAST(&v6)) return BEANS_NET_ERR_RANGE;
        struct ipv6_mreq membership;
        memset(&membership, 0, sizeof membership);
        membership.ipv6mr_multiaddr = v6;
        membership.ipv6mr_interface = 0;
        int option = join ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP;
#if defined(_WIN32)
        if (setsockopt((SOCKET)fd, IPPROTO_IPV6, option,
                       (const char*)&membership, sizeof membership) != 0)
#else
        if (setsockopt((int)fd, IPPROTO_IPV6, option,
                       &membership, sizeof membership) != 0)
#endif
            return 100 + beans_sockx_os_error();
        return BEANS_NET_OK;
    }

    return BEANS_NET_ERR_INVALID;
}
