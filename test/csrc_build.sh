#!/usr/bin/env bash
# csrc manifest rows (G8): a package declares its own C sources; the
# toolchain compiles them — a cached object per source for native links,
# one cached host library for `beansc run` — and rows propagate from a
# dependency to its consumer like link rows.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-csrc.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/mathlib/native" "$tmp/app"

cat > "$tmp/mathlib/beans.pot" <<'POT'
module mathlib
kind library
csrc all "native/fast_add.c"
link macos framework "CoreFoundation"
POT
cat > "$tmp/mathlib/native/fast_add.c" <<'CSRC'
#include "fast_add.h"
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif
#ifndef COMPILER_BIAS
#define COMPILER_BIAS 0
#endif
long long beans_test_fast_add(long long a, long long b) {
    long long platform_bias = 0;
#ifdef __APPLE__
    platform_bias = CFAbsoluteTimeGetCurrent() > 0.0 ? 0 : 1000;
#endif
    return a + b + FAST_BIAS + COMPILER_BIAS + platform_bias;
}
CSRC
cat > "$tmp/mathlib/native/fast_add.h" <<'HDR'
#define FAST_BIAS 40
long long beans_test_fast_add(long long a, long long b);
HDR
cat > "$tmp/mathlib/api.b" <<'LIB'
package mathlib

extern "C" fn beans_test_fast_add(a: int, b: int) -> int

pub fn fast_add(a: int, b: int) -> int {
    var total: int = 0
    unsafe {
        total = beans_test_fast_add(a, b)
    }
    return total
}
LIB

cat > "$tmp/app/beans.pot" <<'POT'
module csrcapp
kind application
require path "../mathlib"
POT
cat > "$tmp/app/main.b" <<'APP'
package main

import std.io
import mathlib

fn main() {
    io.println("fast {mathlib.fast_add(1, 1)}")
}
APP

export BEANS_RUNTIME="$root/runtime/beans_rt.c"

# interpreter: csrc rows propagate from the dependency and resolve externs
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/interp.out"
grep -Fqx "fast 42" "$tmp/interp.out"

# run again warm: the cached library is reused, not rebuilt
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/interp2.out"
grep -Fqx "fast 42" "$tmp/interp2.out"

# A header-only change must invalidate both caches. The first implementation
# hashed only fast_add.c, so this kept printing 42 forever.
cat > "$tmp/mathlib/native/fast_add.h" <<'HDR'
#define FAST_BIAS 41
long long beans_test_fast_add(long long a, long long b);
HDR
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/header.interp.out"
grep -Fqx "fast 43" "$tmp/header.interp.out"
(cd "$tmp/app" && "$root/build/beansc" build main.b -o app.header.bin) \
    >"$tmp/header.build.out" 2>&1
"$tmp/app/app.header.bin" >"$tmp/header.native.out"
grep -Fqx "fast 43" "$tmp/header.native.out"

# A compiler is part of the cache identity. Two compiler commands building
# the same source must get separate interpreter libraries and native objects.
real_cc=$(command -v clang)
cat > "$tmp/cc-a" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "beans csrc test compiler A"
    exit 0
fi
exec "$BEANS_TEST_REAL_CC" -DCOMPILER_BIAS=100 "$@"
SH
cat > "$tmp/cc-b" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "beans csrc test compiler B"
    exit 0
fi
exec "$BEANS_TEST_REAL_CC" -DCOMPILER_BIAS=200 "$@"
SH
chmod +x "$tmp/cc-a" "$tmp/cc-b"
export BEANS_TEST_REAL_CC="$real_cc"

(cd "$tmp/app" && BEANS_CC="$tmp/cc-a" \
    "$root/build/beansc" run main.b) >"$tmp/compiler-a.interp.out"
(cd "$tmp/app" && BEANS_CC="$tmp/cc-b" \
    "$root/build/beansc" run main.b) >"$tmp/compiler-b.interp.out"
(cd "$tmp/app" && BEANS_CC="$tmp/cc-a" \
    "$root/build/beansc" run main.b) >"$tmp/compiler-a-warm.interp.out"
grep -Fqx "fast 143" "$tmp/compiler-a.interp.out"
grep -Fqx "fast 243" "$tmp/compiler-b.interp.out"
grep -Fqx "fast 143" "$tmp/compiler-a-warm.interp.out"

(cd "$tmp/app" && BEANS_CC="$tmp/cc-a" \
    "$root/build/beansc" build main.b -o app.compiler-a.bin) \
    >"$tmp/compiler-a.build.out" 2>&1
(cd "$tmp/app" && BEANS_CC="$tmp/cc-b" \
    "$root/build/beansc" build main.b -o app.compiler-b.bin) \
    >"$tmp/compiler-b.build.out" 2>&1
"$tmp/app/app.compiler-a.bin" >"$tmp/compiler-a.native.out"
"$tmp/app/app.compiler-b.bin" >"$tmp/compiler-b.native.out"
grep -Fqx "fast 143" "$tmp/compiler-a.native.out"
grep -Fqx "fast 243" "$tmp/compiler-b.native.out"

# Restore the original answer for the archive checks below.
cat > "$tmp/mathlib/native/fast_add.h" <<'HDR'
#define FAST_BIAS 40
long long beans_test_fast_add(long long a, long long b);
HDR

# native: the object is compiled, cached, and linked into the binary
(cd "$tmp/app" && "$root/build/beansc" build main.b -o app.bin) \
    >"$tmp/build.out" 2>&1
"$tmp/app/app.bin" >"$tmp/native.out"
grep -Fqx "fast 42" "$tmp/native.out"
ls "$tmp/app/build" | grep -q "^beans_csrc\.fast_add\." || {
    echo "csrc object missing from the build cache" >&2
    exit 1
}

# static archive carries the csrc object
(cd "$tmp/mathlib" && "$root/build/beansc" build --emit static api.b \
    -o libmath.a) >"$tmp/static.out" 2>&1
ar t "$tmp/mathlib/libmath.a" | grep -q "beans_csrc.fast_add" || {
    echo "csrc object missing from the static archive" >&2
    exit 1
}

# a missing file is a manifest error, reported at load time
cat > "$tmp/mathlib/beans.pot" <<'POT'
module mathlib
kind library
csrc all "native/gone.c"
POT
if (cd "$tmp/app" && "$root/build/beansc" check main.b) \
    >"$tmp/missing.out" 2>&1; then
    echo "missing csrc file unexpectedly accepted" >&2
    exit 1
fi
grep -Fq "csrc file does not exist" "$tmp/missing.out"

# ---- cflags rows -----------------------------------------------------------
# A package's own Clang flags, declared where a reader of beans.pot can see
# them. FAST_BIAS is back to 40 by this point, so the baseline is 42.
cat > "$tmp/mathlib/beans.pot" <<'POT'
module mathlib
kind library
csrc all "native/fast_add.c"
cflags all -DCOMPILER_BIAS=5
link macos framework "CoreFoundation"
POT
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/cflags.interp.out"
grep -Fqx "fast 47" "$tmp/cflags.interp.out"
(cd "$tmp/app" && "$root/build/beansc" build main.b -o app.cflags.bin) \
    >"$tmp/cflags.build.out" 2>&1
"$tmp/app/app.cflags.bin" >"$tmp/cflags.native.out"
grep -Fqx "fast 47" "$tmp/cflags.native.out"

# Changing only a flag must recompile. A cache key that ignored the flags
# would hand back the object built with the old -D and answer 48 forever —
# a wrong answer with nothing to notice it by.
cat > "$tmp/mathlib/beans.pot" <<'POT'
module mathlib
kind library
csrc all "native/fast_add.c"
cflags all -DCOMPILER_BIAS=6
link macos framework "CoreFoundation"
POT
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/cflags2.interp.out"
grep -Fqx "fast 48" "$tmp/cflags2.interp.out"
(cd "$tmp/app" && "$root/build/beansc" build main.b -o app.cflags2.bin) \
    >"$tmp/cflags2.build.out" 2>&1
"$tmp/app/app.cflags2.bin" >"$tmp/cflags2.native.out"
grep -Fqx "fast 48" "$tmp/cflags2.native.out"

# Flags belong to the package that wrote them. The app declaring its own must
# not reach the dependency's C, or one package would silently miscompile
# another's code with a define its author never saw.
cat > "$tmp/app/beans.pot" <<'POT'
module csrcapp
kind application
require path "../mathlib"
cflags all -DCOMPILER_BIAS=900
POT
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/cflags.scope.out"
grep -Fqx "fast 48" "$tmp/cflags.scope.out"
(cd "$tmp/app" && "$root/build/beansc" build main.b -o app.scope.bin) \
    >"$tmp/cflags.scope.build" 2>&1
"$tmp/app/app.scope.bin" >"$tmp/cflags.scope.native"
grep -Fqx "fast 48" "$tmp/cflags.scope.native"
cat > "$tmp/app/beans.pot" <<'POT'
module csrcapp
kind application
require path "../mathlib"
POT

# A selector that does not match this host contributes nothing.
cat > "$tmp/mathlib/beans.pot" <<'POT'
module mathlib
kind library
csrc all "native/fast_add.c"
cflags nonesuch-os -DCOMPILER_BIAS=700
link macos framework "CoreFoundation"
POT
(cd "$tmp/app" && "$root/build/beansc" run main.b) >"$tmp/cflags.sel.out"
grep -Fqx "fast 42" "$tmp/cflags.sel.out"

# Flags that would fight the driver for the output are refused at read time.
refuse_cflags() {
    local row=$1
    local message=$2
    cat > "$tmp/mathlib/beans.pot" <<POT
module mathlib
kind library
csrc all "native/fast_add.c"
$row
POT
    if (cd "$tmp/app" && "$root/build/beansc" check main.b) \
        >"$tmp/cflags.bad" 2>&1; then
        echo "cflags row '$row' unexpectedly accepted" >&2
        exit 1
    fi
    grep -Fq "$message" "$tmp/cflags.bad"
}
refuse_cflags "cflags all -o /tmp/hijack.o" \
    "cflags cannot set '-o': the object path belongs to the build, not the package"
refuse_cflags "cflags all -c" \
    "cflags cannot set '-c': every csrc file is already compiled to an object"
refuse_cflags "cflags all" \
    "cflags needs 'cflags <selector> <flag> [<flag>...]'"

cat > "$tmp/mathlib/beans.pot" <<'POT'
module mathlib
kind library
csrc all "native/fast_add.c"
link macos framework "CoreFoundation"
POT
echo "  ok cflags: applied, cached per flag set, package-scoped, validated"

echo "ok csrc build"
