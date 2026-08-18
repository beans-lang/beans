// Shared plumbing for the networking native bridges.
//
// Every bridge entry point follows the std.encoding ABI so both interpreters
// can call it through their existing direct extern-"C" word path (no
// per-signature C trampoline, no C compiler at `beansc run` time):
//
//   - at most three parameters, each a 64-bit integer or a pointer
//   - the return value is a 64-bit integer status or handle
//   - wider argument lists ride in a caller-allocated request buffer of
//     64-bit words; the layout of each request is documented beside the
//     function and mirrored byte-for-byte by the Beans package
//
// Pointers cross as the low 64 bits of a word even on 32-bit targets: Beans
// widens a RawPtr to i64 in its extern ABI, and the bridge narrows it back.
//
// No bridge function reads beyond (pointer, length) it was handed. Beans
// strings and Bytes are never assumed to be NUL-terminated; lengths are
// explicit everywhere. Handles a bridge returns are opaque words owned by
// that bridge; the Beans side frees them through the bridge's own close
// entry point, never through Beans memory management.
#ifndef BEANS_NET_COMMON_H
#define BEANS_NET_COMMON_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

// The API must be reachable by dlsym/GetProcAddress when the bridge is a
// shared library, and by the loader's module walk when it is linked into an
// executable. Objects are compiled with hidden default visibility, so the
// public entry points opt back in explicitly.
// C linkage is part of the contract: a C++ bridge (the ws one reaches for
// C++ only to keep its UTF-8 check tidy) must still export the same plain
// symbol names both interpreters resolve by name.
#if defined(__cplusplus)
  #define BEANS_NET_LINKAGE extern "C"
#else
  #define BEANS_NET_LINKAGE
#endif

#if defined(_WIN32)
  #define BEANS_NET_API BEANS_NET_LINKAGE __declspec(dllexport)
#else
  #define BEANS_NET_API BEANS_NET_LINKAGE __attribute__((visibility("default")))
#endif

// Status codes shared by every networking bridge. 0 is success; each bridge
// adds its own codes above 100 so a misrouted status is obvious in a test
// failure. Negative values never appear: sizes and statuses share a word,
// and a status is only meaningful when the call has no size to report.
enum {
    BEANS_NET_OK = 0,
    BEANS_NET_ERR_INVALID = 1,     // malformed input / bad argument
    BEANS_NET_ERR_RANGE = 2,       // out-of-range index / destination too small
    BEANS_NET_ERR_MEMORY = 3,      // allocation failure
    BEANS_NET_ERR_UNSUPPORTED = 4, // not available on this platform
    BEANS_NET_ERR_CLOSED = 5,      // operation on a closed handle
};

static inline uint64_t beans_net_word(const uint64_t* req, int index) {
    return req[index];
}

static inline void* beans_net_ptr(const uint64_t* req, int index) {
    return (void*)(uintptr_t)req[index];
}

#endif // BEANS_NET_COMMON_H
