// Socket extras for std.net — the operations too specialized for the core
// syscall layer in beans_rt.c but still part of the socket contract. Today
// that is multicast membership; the file exists so the next extra has a
// home that is already cached, routed, and linked per-feature.
//
// Everything here works on a descriptor the Beans side owns; nothing opens
// or closes sockets. Statuses follow beans_net_common.h, with OS errors
// carried as 100+errno so the Beans layer can surface the number without
// this bridge growing a string formatter.

#include "beans_net_common.h"

#if defined(_WIN32)
  #include <winsock2.h>
  #include <ws2tcpip.h>
#else
  #include <sys/types.h>
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <errno.h>
#endif

static int beans_sockx_os_error(void) {
#if defined(_WIN32)
    return (int)WSAGetLastError();
#else
    return errno;
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
