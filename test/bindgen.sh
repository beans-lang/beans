#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/access.h" <<'C'
#include <stdint.h>
typedef struct Handle Handle;
typedef struct Pair {
    int32_t left;
    uint64_t right;
    uint8_t bytes[4];
} Pair;
typedef union Word {
    uint32_t bits;
    float value;
} Word;
typedef int32_t (*Operation)(void*, int32_t);
typedef struct CallbackSlot {
    Operation function;
    void* context;
} CallbackSlot;
typedef enum Status { STATUS_OK = 0, STATUS_BAD = 2 } Status;
extern const int32_t version;
extern _Thread_local int32_t counter;
extern Operation active_operation;
Handle* make_handle(void);
Operation get_operation(void);
int32_t take(Handle*, Pair, Word, void (*callback)(void*, int32_t));
C
"$beansc" bindgen "$tmp/access.h" -o "$tmp/bindings.b" >"$tmp/bindgen.out"
"$beansc" check "$tmp/bindings.b" >"$tmp/check.out"
grep -F 'opaque struct Handle' "$tmp/bindings.b" >"$tmp/match"
grep -F 'union Word' "$tmp/bindings.b" >"$tmp/match"
grep -F 'bytes: [u8; 4]' "$tmp/bindings.b" >"$tmp/match"
grep -F 'thread_local var counter: i32' "$tmp/bindings.b" >"$tmp/match"
grep -F 'fn make_handle() -> RawPtr<Handle>' "$tmp/bindings.b" >"$tmp/match"
grep -F 'callback' "$tmp/bindings.b" >"$tmp/match"
grep -F 'function: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>' \
    "$tmp/bindings.b" >"$tmp/match"
grep -F 'var active_operation: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>' \
    "$tmp/bindings.b" >"$tmp/match"
grep -F 'fn get_operation() -> CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>' \
    "$tmp/bindings.b" >"$tmp/match"
grep -F 'fn status_bad() -> i32 { return 2 }' "$tmp/bindings.b" >"$tmp/match"

# Types belong to the whole translation unit even when symbols belong only to
# the requested header. A public declaration may use aliases, records, enums,
# and callbacks from an included header; those definitions must be available
# for type resolution, but unused included declarations must stay out.
mkdir -p "$tmp/included"
cat >"$tmp/included/dependency.h" <<'C'
typedef unsigned int DependencyCount;
typedef DependencyCount DependencySize;
typedef struct {
    int value;
} DependencyRecord;
typedef struct DependencyUnused {
    int hidden;
} DependencyUnused;
typedef enum {
    DEPENDENCY_OK = 0,
    DEPENDENCY_BAD = 4
} DependencyStatus;
typedef int (*DependencyCallback)(DependencyRecord*, DependencySize);
C
cat >"$tmp/included/api.h" <<'C'
#include "dependency.h"
DependencySize dependency_size_of(DependencyRecord* record);
DependencyStatus dependency_run(DependencyCallback callback,
                                DependencyRecord* record);
C
included=$tmp/included/bindings.b
"$beansc" bindgen "$tmp/included/api.h" -o "$included" \
    >"$tmp/included.out"
"$beansc" check "$included" >"$tmp/included.check"
grep -F 'extern "C" struct DependencyRecord' "$included" >"$tmp/match"
grep -F 'fn dependency_bad() -> i32 { return 4 }' "$included" >"$tmp/match"
grep -F 'fn dependency_size_of(record: RawPtr<DependencyRecord>) -> u32' \
    "$included" >"$tmp/match"
grep -F 'callback: fn(RawPtr<DependencyRecord>, u32) -> i32' \
    "$included" >"$tmp/match"
if grep -F 'DependencyUnused' "$included" >/dev/null; then
    echo "bindgen emitted an unused type from an included header" >&2
    exit 1
fi

# Several requested headers form one binding surface. This keeps a shared
# opaque handle in one Beans package and includes functions declared in the
# common header as well as the service header. --pub makes that surface usable
# from a consumer package.
mkdir -p "$tmp/multi/bindings" "$tmp/multi/consumer"
cat >"$tmp/multi/core.h" <<'C'
#ifndef BEANS_BINDGEN_CORE_H
#define BEANS_BINDGEN_CORE_H
typedef struct CoreHandle CoreHandle;
typedef struct CoreInfo {
    int ready;
    unsigned char tag;
} CoreInfo;
CoreHandle* core_open(void);
void core_close(CoreHandle* handle);
CoreInfo core_info(void);
#endif
C
cat >"$tmp/multi/service.h" <<'C'
#ifndef BEANS_BINDGEN_SERVICE_H
#define BEANS_BINDGEN_SERVICE_H
#include "core.h"
int service_call(CoreHandle* handle, int value);
#endif
C
cat >"$tmp/multi/bindings/beans.pot" <<'MOD'
module bindings
kind library
MOD
"$beansc" bindgen "$tmp/multi/core.h" "$tmp/multi/service.h" \
    -o "$tmp/multi/bindings/bindings.b" --package bindings --pub \
    >"$tmp/multi.out"
multi="$tmp/multi/bindings/bindings.b"
grep -F 'pub extern "C" opaque struct CoreHandle' "$multi" >/dev/null
grep -F 'pub extern "C" fn core_open() -> RawPtr<CoreHandle>' \
    "$multi" >/dev/null
grep -F 'pub extern "C" fn core_close(handle: RawPtr<CoreHandle>)' \
    "$multi" >/dev/null
grep -F 'pub extern "C" fn service_call(handle: RawPtr<CoreHandle>, value: i32) -> i32' \
    "$multi" >/dev/null
# A pub record carries pub fields: C has no private struct members, and a
# by-value API is unusable from a consumer that cannot read Color.r or
# Image.width. The consumer below fails to check without them.
grep -F '    pub ready: i32' "$multi" >/dev/null
grep -F '    pub tag: u8' "$multi" >/dev/null
cat >"$tmp/multi/consumer/beans.pot" <<'MOD'
module consumer
require path "../bindings"
MOD
cat >"$tmp/multi/consumer/main.b" <<'BEANS'
package main

import bindings

fn call(handle: RawPtr<bindings.CoreHandle>) -> i32 {
    unsafe { return bindings.service_call(handle, 7) }
}

fn ready_flag(info: bindings.CoreInfo) -> i32 {
    return info.ready
}

fn main() {}
BEANS
"$beansc" check --locked --offline "$tmp/multi/consumer/main.b" \
    >"$tmp/multi.check"

# Includes alone do not make a header non-empty and do not cause all included
# declarations to leak into the generated file.
printf '#include "dependency.h"\n' >"$tmp/included/empty_api.h"
"$beansc" bindgen "$tmp/included/empty_api.h" \
    -o "$tmp/included/empty.b" >"$tmp/included.empty.out"
"$beansc" check "$tmp/included/empty.b" >"$tmp/included.empty.check"
if grep -F 'Dependency' "$tmp/included/empty.b" >/dev/null; then
    echo "bindgen emitted types for a header that only includes another header" >&2
    exit 1
fi

# C declarators are recursive. These cover a callback returning a callback, a
# callback receiving another callback, a pointer to a callback slot, and the
# nested xDlSym shape used by sqlite3_vfs.
cat >"$tmp/nested_callbacks.h" <<'C'
typedef int (*InnerCallback)(int);
typedef InnerCallback (*CallbackFactory)(int seed);
typedef struct CallbackTable {
    CallbackFactory factory;
    void (*(*lookup)(void*, const char*))(void);
} CallbackTable;
typedef struct NestedOwner {
    struct NestedChild { int value; } *child;
} NestedOwner;
CallbackFactory nested_factory(CallbackFactory factory);
void (*nested_direct(void))(int);
int nested_consume(int (*factory)(int (*callback)(int)));
void nested_install(void (**slot)(int));
NestedOwner* nested_owner(NestedOwner* owner);
C
"$beansc" bindgen "$tmp/nested_callbacks.h" \
    -o "$tmp/nested_callbacks.b" \
    --target x86_64-unknown-linux-gnu >"$tmp/nested.out"
"$beansc" check "$tmp/nested_callbacks.b" >"$tmp/nested.check"
grep -F 'factory: CFunctionPtr<fn(i32) -> CFunctionPtr<fn(i32) -> i32> >' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'lookup: CFunctionPtr<fn(RawPtr<u8>, RawPtr<i8>) -> CFunctionPtr<fn()> >' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'fn nested_factory(factory: fn(i32) -> CFunctionPtr<fn(i32) -> i32>) -> CFunctionPtr<fn(i32) -> CFunctionPtr<fn(i32) -> i32> >' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'fn nested_direct() -> CFunctionPtr<fn(i32)>' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'fn nested_consume(factory: fn(CFunctionPtr<fn(i32) -> i32>) -> i32) -> i32' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'fn nested_install(slot: RawPtr<CFunctionPtr<fn(i32)> >)' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'extern "C" struct NestedChild' \
    "$tmp/nested_callbacks.b" >"$tmp/match"
grep -F 'child: RawPtr<NestedChild>' \
    "$tmp/nested_callbacks.b" >"$tmp/match"

# A variadic *import* binds: the declaration carries `...` and each call site
# writes its own tail. A variadic *callback* still cannot — `fn(...)` would
# have to name a tail that only a call site knows — so it is refused wherever a
# function pointer is stored, passed or returned.
cat >"$tmp/variadic.h" <<'C'
int logline(const char*, ...);
int ioctl_like(int fd, unsigned long request, ...);
C
# Pinned to one target: plain `char` is signed on x86-64 and unsigned on ARM
# Linux, so `const char*` binds as RawPtr<i8> on one and RawPtr<u8> on the
# other. The assertions below name a concrete type, so the ABI has to be a
# constant here rather than the host's.
"$beansc" bindgen "$tmp/variadic.h" -o "$tmp/variadic.b" \
    --target x86_64-unknown-linux-gnu >"$tmp/variadic.out"
"$beansc" check "$tmp/variadic.b" >"$tmp/variadic.check"
grep -F 'fn logline(arg0: RawPtr<i8>, ...) -> i32' "$tmp/variadic.b" >"$tmp/match"
grep -F 'fn ioctl_like(fd: i32, request: u64, ...) -> i32' \
    "$tmp/variadic.b" >"$tmp/match"

cat >"$tmp/unsupported.h" <<'C'
typedef int (*Logger)(const char*, ...);
int install(Logger log);
C
if "$beansc" bindgen "$tmp/unsupported.h" -o "$tmp/bad.b" \
    >"$tmp/bad.out" 2>&1; then
    echo "bindgen accepted a variadic callback type" >&2
    exit 1
fi
grep -F 'variadic C callback type is unsupported' "$tmp/bad.out" >"$tmp/match"
"$beansc" bindgen "$tmp/unsupported.h" -o "$tmp/allowed.b" \
    --allow-unsupported >"$tmp/allowed.out"
grep -F 'skipped:' "$tmp/allowed.b" >"$tmp/match"

# Bindings are generated to be dropped into a real project, and every file in a
# package declares that package. Without --package the output has no clause at
# all, which loads only as a lone file — so a generated file beside a main.b was
# refused by the loader and nothing here noticed, because this file only ever
# checked the bindings on their own.
project="$tmp/project"
mkdir -p "$project"
cat >"$project/beans.pot" <<'MOD'
module bindgen_probe
MOD
cat >"$project/main.b" <<'BEANS'
package main

import std.io

fn main() {
    var seen: i32 = 0
    unsafe { seen = version }
    io.println("{seen}")
}
BEANS
"$beansc" bindgen "$tmp/access.h" -o "$project/bindings.b" --package main \
    >"$tmp/pkg.out"
head -3 "$project/bindings.b" | grep -Fx 'package main' >"$tmp/match"
"$beansc" check "$project/main.b" >"$tmp/pkg.check"

# The same generation without --package is still a valid lone file, and it is
# still refused inside the package — that refusal is the whole reason the option
# exists, so it is checked rather than assumed.
"$beansc" bindgen "$tmp/access.h" -o "$project/bindings.b" >"$tmp/nopkg.out"
if "$beansc" check "$project/main.b" >"$tmp/nopkg.check" 2>&1; then
    echo "bindgen: a clause-less file was accepted inside a package" >&2
    cat "$tmp/nopkg.check" >&2
    exit 1
fi
grep -F 'has no package clause' "$tmp/nopkg.check" >/dev/null

# A synthetic header shaped like the C libraries that bindgen used to choke on.
# Every construct here broke it: the handle a macro builds, Clang's nullability
# annotations, a callback returning void*, size_t, and a pointer to a handle.
# It only includes <stddef.h>, which Clang carries itself, so it parses for a
# cross target with no sysroot.
mkdir -p "$tmp/probe"
cat >"$tmp/probe/probe_macros.h" <<'C'
#ifndef PROBE_MACROS_H_
#define PROBE_MACROS_H_
#define PROBE_DEFINE_HANDLE(name) typedef struct name##_ *name;
#ifdef __clang__
#define PROBE_NULLABLE _Nullable
#define PROBE_NONNULL _Nonnull
#else
#define PROBE_NULLABLE
#define PROBE_NONNULL
#endif
/* Expanded here rather than in the header bindgen is asked about. A macro-made
   declaration belongs to the file the macro was used in, so this one is not
   part of probe.h and must stay out of the bindings. */
PROBE_DEFINE_HANDLE(ProbeExcluded)
#endif
C
cat >"$tmp/probe/probe.h" <<'C'
#include <stddef.h>
#include "probe_macros.h"

/* The first declaration of the header is macro-made on purpose. Clang spells
   the pasted name in "<scratch space>" and there is no earlier declaration of
   this file to inherit a location from, so nothing but the expansion location
   can say that this handle belongs here. */
PROBE_DEFINE_HANDLE(ProbeTexture)
PROBE_DEFINE_HANDLE(ProbeContext)

typedef void *PROBE_NULLABLE (*ProbeAllocator)(
    void *PROBE_NULLABLE user_data,
    const char *PROBE_NONNULL tag,
    size_t size);

typedef struct ProbeBuffer {
  void *PROBE_NULLABLE data;
  size_t length;
  ProbeAllocator PROBE_NULLABLE allocator;
} ProbeBuffer;

ProbeTexture PROBE_NULLABLE ProbeTextureNew(ProbeContext PROBE_NONNULL context,
                                            size_t bytes);
void ProbeTextureCollect(ProbeTexture PROBE_NONNULL *PROBE_NULLABLE textures,
                         size_t count);
size_t ProbeBufferHash(const ProbeBuffer *PROBE_NONNULL buffer,
                       ProbeAllocator PROBE_NULLABLE allocator);
C

probe=$tmp/probe/probe.b
"$beansc" bindgen "$tmp/probe/probe.h" -o "$probe" \
    --target x86_64-unknown-linux-gnu >"$tmp/probe.out"
"$beansc" check "$probe" >"$tmp/probe.check"

# The handle the macro built is the only reason the rest of the file is seen.
grep -F 'extern "C" opaque struct ProbeTexture' "$probe" >"$tmp/match"
grep -F 'extern "C" opaque struct ProbeContext' "$probe" >"$tmp/match"
# ... and the one whose macro ran in another header is not ours to bind.
if grep -F 'ProbeExcluded' "$probe" >/dev/null; then
    echo "bindgen bound a handle expanded outside the header" >&2
    exit 1
fi
# A callback returning void* is a pointer result, not an unsupported scalar.
grep -F 'allocator: fn(RawPtr<u8>, RawPtr<i8>, u64) -> RawPtr<u8>' "$probe" \
    >"$tmp/match"
# size_t is pointer-width, and a pointer to a handle needs a spaced close.
grep -F 'fn probetexturenew(context: RawPtr<ProbeContext>, bytes: u64)' \
    "$probe" >"$tmp/match"
grep -F 'textures: RawPtr<RawPtr<ProbeTexture> >, count: u64' "$probe" \
    >"$tmp/match"
grep -F 'length: u64' "$probe" >"$tmp/match"
if grep -F 'RawPtr<RawPtr<ProbeTexture>>' "$probe" >/dev/null; then
    echo "bindgen closed nested pointers with a shift token" >&2
    exit 1
fi
# Nullability says nothing about layout and never reaches the output.
if grep -E '_Nullable|_Nonnull|_Null_unspecified' "$probe" >/dev/null; then
    echo "bindgen leaked a nullability qualifier" >&2
    grep -nE '_Nullable|_Nonnull|_Null_unspecified' "$probe" >&2
    exit 1
fi

# size_t follows the target's pointer width rather than its C spelling. Windows
# is the case that makes the difference visible: `unsigned long` is 32 bits
# there, and size_t is still 64.
"$beansc" bindgen "$tmp/probe/probe.h" -o "$tmp/probe/probe32.b" \
    --target i686-unknown-linux-gnu >"$tmp/probe32.out"
grep -F 'bytes: u32' "$tmp/probe/probe32.b" >"$tmp/match"
grep -F 'length: u32' "$tmp/probe/probe32.b" >"$tmp/match"
"$beansc" bindgen "$tmp/probe/probe.h" -o "$tmp/probe/probewin.b" \
    --target x86_64-pc-windows-gnu >"$tmp/probewin.out"
grep -F 'bytes: u64' "$tmp/probe/probewin.b" >"$tmp/match"

# The C scalar types whose width is the target's choice, not the host's. Each
# expectation below is what Clang itself reports for that target, which is
# where bindgen gets the answer too.
cat >"$tmp/scalars.h" <<'C'
#include <stddef.h>
long l_value(long a, unsigned long b);
size_t s_value(size_t a, ptrdiff_t b);
char c_value(char a, signed char b, unsigned char c);
short h_value(short a, unsigned short b);
int i_value(int a, unsigned int b);
long long q_value(long long a, unsigned long long b);
double d_value(float a, double b);
C
scalars() { # target, then the greps that must match
    local target=$1
    shift
    "$beansc" bindgen "$tmp/scalars.h" -o "$tmp/scalars.b" \
        --target "$target" >"$tmp/scalars.out"
    local wanted
    for wanted in "$@"; do
        grep -F "$wanted" "$tmp/scalars.b" >"$tmp/match" || {
            echo "bindgen: $target did not produce '$wanted'" >&2
            cat "$tmp/scalars.b" >&2
            exit 1
        }
    done
}
# LP64: long follows the pointer.
scalars x86_64-unknown-linux-gnu \
    'fn l_value(a: i64, b: u64) -> i64' \
    'fn s_value(a: u64, b: i64) -> u64' \
    'fn c_value(a: i8, b: i8, c: u8) -> i8'
# LLP64: pointers are 64-bit and long is not. Mapping long through the pointer
# width, or size_t through unsigned long, gets exactly this target wrong.
scalars x86_64-pc-windows-msvc \
    'fn l_value(a: i32, b: u32) -> i32' \
    'fn s_value(a: u64, b: i64) -> u64'
# ILP32: everything narrows together.
scalars i686-unknown-linux-gnu \
    'fn l_value(a: i32, b: u32) -> i32' \
    'fn s_value(a: u32, b: i32) -> u32'
# Plain char is unsigned here while `signed char` still is not, which is a
# distinction a fixed i8 mapping cannot make.
scalars aarch64-unknown-linux-gnu \
    'fn c_value(a: u8, b: i8, c: u8) -> u8' \
    'fn l_value(a: i64, b: u64) -> i64'
# The widths that do not move stay put on every one of them.
for target in x86_64-unknown-linux-gnu x86_64-pc-windows-msvc \
              i686-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    scalars "$target" \
        'fn h_value(a: i16, b: u16) -> i16' \
        'fn i_value(a: i32, b: u32) -> i32' \
        'fn q_value(a: i64, b: u64) -> i64' \
        'fn d_value(a: f32, b: f64) -> f64'
done

# An enum binds when Clang gave it the plain signed-int representation, and
# only then. Implicit successors and negative values have to survive exactly.
cat >"$tmp/enum_ok.h" <<'C'
typedef enum Normal { NORM_A = 0, NORM_B = -3, NORM_C } Normal;
Normal normal_of(int value);
C
"$beansc" bindgen "$tmp/enum_ok.h" -o "$tmp/enum_ok.b" >"$tmp/enum.out"
"$beansc" check "$tmp/enum_ok.b" >"$tmp/enum.check"
grep -F 'fn norm_a() -> i32 { return 0 }' "$tmp/enum_ok.b" >"$tmp/match"
grep -F 'fn norm_b() -> i32 { return -3 }' "$tmp/enum_ok.b" >"$tmp/match"
grep -F 'fn norm_c() -> i32 { return -2 }' "$tmp/enum_ok.b" >"$tmp/match"

refuse() { # file, expected message fragment, description
    if "$beansc" bindgen "$1" -o "$tmp/refused.b" ${4:+-- $4} \
        >"$tmp/refused.out" 2>&1; then
        echo "bindgen accepted $3" >&2
        cat "$tmp/refused.out" >&2
        exit 1
    fi
    grep -F "$2" "$tmp/refused.out" >"$tmp/match" || {
        echo "bindgen: $3 gave the wrong diagnostic" >&2
        cat "$tmp/refused.out" >&2
        exit 1
    }
}

# A value past int makes Clang widen the whole enum, which would change what
# every constant in it means.
cat >"$tmp/enum_big.h" <<'C'
typedef enum Big { BIG_A = 0, BIG_B = 2147483648u } Big;
void use_big(Big value);
C
refuse "$tmp/enum_big.h" "rather than int" "an enum widened past int"
cat >"$tmp/enum_fixed.h" <<'C'
typedef enum Fixed : unsigned char { FIX_A = 1 } Fixed;
void use_fixed(Fixed value);
C
refuse "$tmp/enum_fixed.h" "fixed underlying type" "a fixed-underlying enum" \
    -std=c23

# ABI features bindgen cannot reproduce exactly have to fail loudly. Producing
# a plausible-looking declaration for any of these is worse than refusing.
cat >"$tmp/packed.h" <<'C'
struct __attribute__((packed)) Packed { int a; long long b; };
void use_packed(struct Packed value);
C
refuse "$tmp/packed.h" "is packed" "a packed record"
cat >"$tmp/aligned.h" <<'C'
struct __attribute__((aligned(32))) Aligned { int a; };
void use_aligned(struct Aligned value);
C
refuse "$tmp/aligned.h" "explicit alignment" "an over-aligned record"
cat >"$tmp/field_aligned.h" <<'C'
struct FieldAligned { char first; int value __attribute__((aligned(32))); };
void use_field_aligned(struct FieldAligned value);
C
refuse "$tmp/field_aligned.h" "field 'value' in record 'FieldAligned' carries a layout attribute" \
    "an over-aligned record field"
cat >"$tmp/pragma.h" <<'C'
#pragma pack(push, 1)
struct Pragma { int a; long long b; };
#pragma pack(pop)
void use_pragma(struct Pragma value);
C
refuse "$tmp/pragma.h" "#pragma pack" "a #pragma pack record"
cat >"$tmp/atomic.h" <<'C'
struct Counter { _Atomic int value; };
void use_counter(struct Counter value);
C
refuse "$tmp/atomic.h" "_Atomic" "an atomic field"
cat >"$tmp/anon.h" <<'C'
struct Outer { struct { int x; int y; }; };
void use_outer(struct Outer value);
C
refuse "$tmp/anon.h" "anonymous record" "an anonymous record"
# stdcall only exists on 32-bit x86 — Clang drops it elsewhere, so the target
# has to be one where the convention is real.
cat >"$tmp/conv.h" <<'C'
int __attribute__((stdcall)) conv(int value);
C
if "$beansc" bindgen "$tmp/conv.h" -o "$tmp/conv.b" \
    --target i686-unknown-linux-gnu >"$tmp/conv.out" 2>&1; then
    echo "bindgen accepted a non-default calling convention" >&2
    exit 1
fi
grep -F 'ABI attribute' "$tmp/conv.out" >"$tmp/match"
cat >"$tmp/bitfield.h" <<'C'
struct Bits { unsigned a : 3; unsigned b : 5; };
void use_bits(struct Bits value);
C
refuse "$tmp/bitfield.h" "bitfield" "a bitfield"
cat >"$tmp/wide_callback.h" <<'C'
struct WideCallback {
    void (*callback)(int, int, int, int, int, int, int);
};
void use_wide_callback(struct WideCallback value);
C
refuse "$tmp/wide_callback.h" "more than 6 parameters" \
    "a callback wider than the C callback bridge"
# Types Beans cannot represent exactly are refused rather than rounded to a
# near-enough one.
for spelling in 'long double' '__int128' '_Complex double'; do
    printf 'void takes(%s value);\n' "$spelling" >"$tmp/exact.h"
    refuse "$tmp/exact.h" "unsupported C type" "the C type $spelling"
done

# In allow mode an unsafe declaration must disappear as one unit. Anything
# whose layout depends on it must disappear too. Valid unrelated declarations
# remain usable.
cat >"$tmp/partly_unsupported.h" <<'C'
struct Good { int value; };
struct __attribute__((packed)) Bad { int value; long long wide; };
struct DependsOnBad { struct Bad bad; int tail; };
void use_good(struct Good value);
void use_bad(struct Bad value);
void use_depends(struct DependsOnBad value);
C
"$beansc" bindgen "$tmp/partly_unsupported.h" \
    -o "$tmp/partly_unsupported.b" --allow-unsupported \
    >"$tmp/partly_unsupported.out"
grep -F 'extern "C" struct Good' "$tmp/partly_unsupported.b" >"$tmp/match"
grep -F 'fn use_good(value: Good)' "$tmp/partly_unsupported.b" >"$tmp/match"
for unsafe_decl in \
    'extern "C" struct Bad' \
    'extern "C" struct DependsOnBad' \
    'fn use_bad(' \
    'fn use_depends('; do
    if grep -F "$unsafe_decl" "$tmp/partly_unsupported.b" >/dev/null; then
        echo "bindgen emitted unsafe declaration '$unsafe_decl' in allow mode" >&2
        cat "$tmp/partly_unsupported.b" >&2
        exit 1
    fi
done
"$beansc" check "$tmp/partly_unsupported.b" >"$tmp/partly_unsupported.check"

# A skip comment names the declaration it dropped. A bare "flexible arrays
# are unsupported" against a 300-function header leaves the reader to
# rediscover the victim by hand; the sqlite3.h binding did exactly that.
cat >"$tmp/named_skips.h" <<'C'
struct Tail { int used; char data[]; };
void uses_tail(struct Tail tail);
void wide(void (*callback)(int, int, int, int, int, int, int));
int fine(int value);
C
"$beansc" bindgen "$tmp/named_skips.h" \
    -o "$tmp/named_skips.b" --allow-unsupported \
    >"$tmp/named_skips.out"
grep -F "// skipped: record 'Tail': flexible arrays are unsupported" \
    "$tmp/named_skips.b" >"$tmp/match"
grep -F "// skipped: declaration 'wide': C callback has more than 6 parameters" \
    "$tmp/named_skips.b" >"$tmp/match"
grep -F 'fn fine(' "$tmp/named_skips.b" >"$tmp/match"
if grep -F "fn uses_tail(" "$tmp/named_skips.b" >/dev/null; then
    echo "bindgen emitted a declaration whose record was dropped" >&2
    exit 1
fi
"$beansc" check "$tmp/named_skips.b" >"$tmp/named_skips.check"

# Success has to mean the bindings are worth having. A header whose only
# declarations cannot be bound must say so rather than write a lone comment.
cat >"$tmp/hidden.h" <<'C'
static int helper(void) { return 1; }
C
refuse "$tmp/hidden.h" "could be bound" "a header with nothing bindable"
# A header that declares nothing is a different case and stays legal.
printf '/* deliberately empty */\n' >"$tmp/blank.h"
"$beansc" bindgen "$tmp/blank.h" -o "$tmp/blank.b" >"$tmp/blank.out"
"$beansc" check "$tmp/blank.b" >"$tmp/blank.check"

# --only has to answer for a name it could not deliver.
cat >"$tmp/linkage.h" <<'C'
#include <stdint.h>
static int32_t helper(int32_t x) { return x; }
static inline int32_t inline_helper(int32_t x) { return x; }
static int32_t hidden_global;
extern int32_t beans_bindgen_probe_global;
int32_t beans_bindgen_probe_double(int32_t value);
C
if "$beansc" bindgen "$tmp/linkage.h" -o "$tmp/only.b" --only helper \
    >"$tmp/only.out" 2>&1; then
    echo "bindgen bound a static function through --only" >&2
    exit 1
fi
grep -F 'not externally linkable' "$tmp/only.out" >"$tmp/match"
if "$beansc" bindgen "$tmp/linkage.h" -o "$tmp/only.b" --only absent \
    >"$tmp/miss.out" 2>&1; then
    echo "bindgen reported success for an unmatched --only" >&2
    exit 1
fi
grep -F 'does not declare' "$tmp/miss.out" >"$tmp/match"


echo "bindgen ok"
