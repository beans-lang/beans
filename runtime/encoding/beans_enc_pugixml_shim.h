// The two C++ runtime symbols the pugixml bridge still references, and
// nothing else. Included by beans_enc_xml.cpp only.
//
// Why any shim at all: pugixml's in-memory serialization goes through
// `pugi::xml_writer`, an abstract class with a virtual destructor, so the
// derived sink's vtable carries a deleting-destructor slot (referencing
// `operator delete`) and the pure-virtual placeholder — even though the sink
// only ever lives on the stack and is never deleted through a base pointer.
// Beans links programs with the plain C driver, so no C++ standard library
// is on the link line to supply them.
//
// The simdutf bridge needs no shim: it is built with SIMDUTF_NO_LIBCXX=1,
// upstream's supported mode for exactly this situation, and its object has
// no C++ runtime undefined symbols at all.
//
// Verified by `nm -u` (see test/encoding_symbols.sh, which fails the build
// if this list grows):
//   macOS arm64  : __ZdlPv, ___cxa_pure_virtual
//   Linux glibc  : _ZdlPv, _ZdlPvm, __cxa_pure_virtual
//   Linux musl   : _ZdlPv, _ZdlPvm, __cxa_pure_virtual
//
// Windows is NOT verified. The Itanium spellings below exist on MinGW and
// GNullVM, which use the Itanium C++ ABI; MSVC uses its own ABI where the
// pure-virtual hook is `_purecall` and `operator delete` comes from
// vcruntime, which the MSVC link always pulls in. That path is written out
// below but has never been compiled or run, and no Windows support is
// claimed for std.encoding.xml until it has been.
#ifndef BEANS_ENC_PUGIXML_SHIM_H
#define BEANS_ENC_PUGIXML_SHIM_H

#include <stddef.h>
#include <stdlib.h>

#if defined(_MSC_VER)

// MSVC ABI. vcruntime defines every `operator delete` overload and the
// `_purecall` hook, so nothing is defined here; a definition would collide
// with the CRT's. UNVERIFIED — see the file comment.

#else

// Itanium C++ ABI (macOS, Linux glibc and musl, MinGW, GNullVM).
//
// Weak, so a program that does link a real C++ runtime keeps that runtime's
// definitions rather than colliding with these. The implicit declarations of
// `operator delete` carry default visibility, so these must not narrow it.
//
// pugixml allocates through its own function pointers, which default to
// malloc/free, so routing operator delete to free is the matching
// deallocator for anything that could reach it. In practice nothing does:
// the sink is a stack value.
__attribute__((weak)) void operator delete(void* block) noexcept { free(block); }
__attribute__((weak)) void operator delete(void* block, size_t) noexcept { free(block); }
__attribute__((weak)) void operator delete[](void* block) noexcept { free(block); }
__attribute__((weak)) void operator delete[](void* block, size_t) noexcept { free(block); }

extern "C" {
// Reaching this means a pure virtual was called during construction or
// destruction — impossible through this bridge, and a trap beats an
// undefined symbol at link time.
__attribute__((weak)) void __cxa_pure_virtual(void) { abort(); }
}

#endif

#endif // BEANS_ENC_PUGIXML_SHIM_H
