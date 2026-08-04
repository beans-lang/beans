// Minimal C++ runtime shims for the pugixml and simdutf bridges.
//
// Both libraries are compiled with -fno-exceptions and -fno-rtti, and Beans
// links programs with the plain C driver, so no C++ standard library is on
// the link line. The only C++ runtime symbols the two objects still reference
// are the ones below (verified by `nm -u` on macOS arm64 and Alpine musl
// x86-64): operator delete, __cxa_pure_virtual, and the function-local static
// guards. They are defined weak so a program that does link a real C++
// runtime keeps the real definitions.
//
// This header is included exactly once per bridge translation unit.
#ifndef BEANS_ENC_CXX_SHIM_H
#define BEANS_ENC_CXX_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

// The implicit compiler declarations of operator delete carry default
// visibility, so the definitions must not narrow it — weak alone is enough
// to keep a real C++ runtime's definitions when one is linked.
#define BEANS_ENC_SHIM __attribute__((weak))

// Neither library calls operator new (pugixml allocates through its own
// function pointers, simdutf's base64 path allocates nothing), but virtual
// destructors reference operator delete. Route to free: the only allocations
// that could reach it came from malloc.
BEANS_ENC_SHIM void operator delete(void* p) noexcept { free(p); }
BEANS_ENC_SHIM void operator delete(void* p, size_t) noexcept { free(p); }
BEANS_ENC_SHIM void operator delete[](void* p) noexcept { free(p); }
BEANS_ENC_SHIM void operator delete[](void* p, size_t) noexcept { free(p); }

extern "C" {

// A pure virtual call is a bug that cannot happen through these bridges; a
// trap beats an undefined symbol at link time.
BEANS_ENC_SHIM void __cxa_pure_virtual(void) { abort(); }

// Function-local static initialization guards (simdutf's implementation
// dispatch uses one). The full Itanium contract, one atomic byte: 0 = not
// initialized, 1 = done. Initialization races fall back to a spin on the
// in-progress byte; Beans classes are non-Send so the bridge is effectively
// single-threaded per document, but simdutf's dispatch static may be touched
// from several Beans threads doing independent base64 calls.
BEANS_ENC_SHIM int __cxa_guard_acquire(uint64_t* guard) {
    unsigned char* state = (unsigned char*)guard;
    for (;;) {
        unsigned char done = __atomic_load_n(state, __ATOMIC_ACQUIRE);
        if (done == 1) return 0;
        unsigned char expected = 0;
        if (__atomic_compare_exchange_n(state + 1, &expected, 1, 0,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            return 1;
        }
    }
}

BEANS_ENC_SHIM void __cxa_guard_release(uint64_t* guard) {
    unsigned char* state = (unsigned char*)guard;
    __atomic_store_n(state, 1, __ATOMIC_RELEASE);
    __atomic_store_n(state + 1, 0, __ATOMIC_RELEASE);
}

BEANS_ENC_SHIM void __cxa_guard_abort(uint64_t* guard) {
    unsigned char* state = (unsigned char*)guard;
    __atomic_store_n(state + 1, 0, __ATOMIC_RELEASE);
}

} // extern "C"

#endif // BEANS_ENC_CXX_SHIM_H
