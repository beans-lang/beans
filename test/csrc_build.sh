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
POT
cat > "$tmp/mathlib/native/fast_add.c" <<'CSRC'
#include "fast_add.h"
long long beans_test_fast_add(long long a, long long b) {
    return a + b + FAST_BIAS;
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

echo "ok csrc build"
