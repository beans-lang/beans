#!/usr/bin/env bash
set -euo pipefail

# Bindings are only worth anything if the symbols in them exist. Checking the
# generated text alone cannot tell an import that resolves from one that does
# not, so this builds the C side for real and links against it: a binding for
# a `static` helper would fail here and nowhere else.

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/link_probe.h" <<'C'
#include <stdint.h>

/* Internal to its translation unit: there is no symbol to import. */
static int32_t link_probe_scale(int32_t value) { return value + value; }

/* Header-only, so C is not required to emit a definition for it either. */
static inline int32_t link_probe_bump(int32_t value) {
  return link_probe_scale(value) + 1;
}

/* GNU extern-inline semantics also do not promise an out-of-line symbol. */
extern inline __attribute__((gnu_inline))
int32_t link_probe_gnu_inline(int32_t value) {
  return value + 3;
}

extern int32_t link_probe_base;
int32_t link_probe_double(int32_t value);
C
cat >"$tmp/link_probe.c" <<'C'
#include "link_probe.h"
int32_t link_probe_base = 21;
int32_t link_probe_double(int32_t value) { return link_probe_scale(value); }
C

mkdir -p "$tmp/project"
# The library lands beside beans.pot so the package's own search path finds it.
if [[ $(uname -s) == Darwin ]]; then
    library="$tmp/project/liblink_probe.dylib"
    clang -dynamiclib "$tmp/link_probe.c" -I"$tmp" -o "$library"
    preload=DYLD_INSERT_LIBRARIES
    library_path=DYLD_LIBRARY_PATH
else
    library="$tmp/project/liblink_probe.so"
    clang -shared -fPIC "$tmp/link_probe.c" -I"$tmp" -o "$library"
    preload=LD_PRELOAD
    library_path=LD_LIBRARY_PATH
fi

cat >"$tmp/project/beans.pot" <<'MOD'
module link_probe
link all search "."
link all library "link_probe"
MOD
"$beansc" bindgen "$tmp/link_probe.h" -o "$tmp/project/bindings.b" \
    --package main >"$tmp/bindgen.out"

# The external declarations are there ...
grep -F 'extern "C" fn link_probe_double(value: i32) -> i32' \
    "$tmp/project/bindings.b" >"$tmp/match"
grep -F 'extern "C" var link_probe_base: i32' \
    "$tmp/project/bindings.b" >"$tmp/match"
# ... and the ones with no symbol behind them are not, under any spelling.
for internal in link_probe_scale link_probe_bump link_probe_gnu_inline; do
    if grep -F "$internal" "$tmp/project/bindings.b" >/dev/null; then
        echo "bindgen imported '$internal', which has no external symbol" >&2
        cat "$tmp/project/bindings.b" >&2
        exit 1
    fi
done

cat >"$tmp/project/main.b" <<'BEANS'
package main

import std.io

fn main() {
    unsafe {
        io.println(link_probe_double(21))
        io.println(link_probe_base)
    }
}
BEANS

"$beansc" check "$tmp/project/main.b" >"$tmp/check.out"
if ! env "$preload=$library" "$beansc" run "$tmp/project/main.b" \
    >"$tmp/interp.out" 2>&1; then
    cat "$tmp/interp.out" >&2
    exit 1
fi
if ! "$beansc" build "$tmp/project/main.b" -o "$tmp/native" \
    >"$tmp/build.out" 2>&1; then
    cat "$tmp/build.out" >&2
    exit 1
fi
env "$library_path=$tmp/project" "$tmp/native" >"$tmp/native.out"
cat >"$tmp/expected" <<'OUT'
42
21
OUT
diff -u "$tmp/expected" "$tmp/native.out"
diff -u "$tmp/expected" "$tmp/interp.out"

# On ELF hosts the loadable object is often only the versioned soname:
# glibc 2.34+ ships lib<name>.so as a linker script the dynamic loader
# refuses, and a bare runtime package carries lib<name>.so.6 with no dev
# symlink at all. The interpreter has to reach the versioned spelling —
# `link linux library "m"` broke exactly this way on Ubuntu 24.04.
if [[ $(uname -s) != Darwin ]]; then
    mkdir -p "$tmp/versioned"
    cp "$tmp/project/main.b" "$tmp/project/bindings.b" "$tmp/versioned/"
    clang -shared -fPIC "$tmp/link_probe.c" -I"$tmp" \
        -o "$tmp/versioned/liblink_probe.so.6"
    cat >"$tmp/versioned/beans.pot" <<'MOD'
module link_probe
link all search "."
link all library "link_probe"
MOD
    if ! "$beansc" run "$tmp/versioned/main.b" \
        >"$tmp/versioned.out" 2>&1; then
        cat "$tmp/versioned.out" >&2
        exit 1
    fi
    diff -u "$tmp/expected" "$tmp/versioned.out"
fi

echo "bindgen link ok"
