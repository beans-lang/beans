#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
stage0=${BEANSC0:-"$root/build/beansc0"}
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

cat >"$tmp/unsupported.h" <<'C'
int variadic(const char*, ...);
C
if "$beansc" bindgen "$tmp/unsupported.h" -o "$tmp/bad.b" \
    >"$tmp/bad.out" 2>&1; then
    echo "bindgen accepted varargs" >&2
    exit 1
fi
"$beansc" bindgen "$tmp/unsupported.h" -o "$tmp/allowed.b" \
    --allow-unsupported >"$tmp/allowed.out"
grep -F 'skipped: variadic function' "$tmp/allowed.b" >"$tmp/match"

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

# The two bindgen implementations have to agree byte for byte. Without the
# stage-0 compiler there is nothing to compare against, so say so rather than
# passing quietly.
if [ -x "$stage0" ]; then
    "$stage0" bindgen "$tmp/probe/probe.h" -o "$tmp/probe/stage0.b" \
        --target x86_64-unknown-linux-gnu >"$tmp/probe.stage0.out"
    cmp "$probe" "$tmp/probe/stage0.b"
    for target in x86_64-unknown-linux-gnu x86_64-pc-windows-msvc \
                  i686-unknown-linux-gnu aarch64-unknown-linux-gnu; do
        "$stage0" bindgen "$tmp/scalars.h" -o "$tmp/scalars.stage0.b" \
            --target "$target" >"$tmp/scalars.stage0.out"
        "$beansc" bindgen "$tmp/scalars.h" -o "$tmp/scalars.self.b" \
            --target "$target" >"$tmp/scalars.self.out"
        cmp "$tmp/scalars.stage0.b" "$tmp/scalars.self.b"
    done
    "$stage0" bindgen "$tmp/enum_ok.h" -o "$tmp/enum.stage0.b" \
        >"$tmp/enum.stage0.out"
    cmp "$tmp/enum_ok.b" "$tmp/enum.stage0.b"
    "$stage0" bindgen "$tmp/access.h" -o "$tmp/access.stage0.b" \
        >"$tmp/access.stage0.out"
    cmp "$tmp/bindings.b" "$tmp/access.stage0.b"
    "$stage0" bindgen "$tmp/partly_unsupported.h" \
        -o "$tmp/partly_unsupported.stage0.b" --allow-unsupported \
        >"$tmp/partly_unsupported.stage0.out"
    cmp "$tmp/partly_unsupported.b" "$tmp/partly_unsupported.stage0.b"
else
    echo "bindgen: no $stage0, skipping the stage-0 output comparison" >&2
fi

echo "bindgen ok"
