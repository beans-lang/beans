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
typedef enum Status { STATUS_OK = 0, STATUS_BAD = 2 } Status;
extern const int32_t version;
extern _Thread_local int32_t counter;
Handle* make_handle(void);
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

# The two bindgen implementations have to agree byte for byte. Without the
# stage-0 compiler there is nothing to compare against, so say so rather than
# passing quietly.
if [ -x "$stage0" ]; then
    "$stage0" bindgen "$tmp/probe/probe.h" -o "$tmp/probe/stage0.b" \
        --target x86_64-unknown-linux-gnu >"$tmp/probe.stage0.out"
    cmp "$probe" "$tmp/probe/stage0.b"
else
    echo "bindgen: no $stage0, skipping the stage-0 output comparison" >&2
fi

echo "bindgen ok"
