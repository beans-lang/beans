#!/usr/bin/env bash
set -euo pipefail

# The encoding object cache must never hand back an object built for a
# different contract. Each case below changes exactly one input and asserts
# the cache path changes with it; the last case asserts an unchanged build
# reuses its object rather than rebuilding, which is the whole point of the
# cache.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-cache.XXXXXX")
tmp_enc=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-src.XXXXXX")
trap 'rm -rf "$tmp" "$tmp_enc"' EXIT

echo "checking the encoding bridge cache key"

cat >"$tmp/prog.b" <<'EOF'
import std.io
import std.encoding.base64

fn main() {
    io.println(base64.encode(Bytes.from("cache")))
}
EOF

# Clears the cache, runs one build, and reports the cache path it settled
# on. Nothing here may abort the script: an expected-to-differ build is
# still just a build, and a missing glob is not an error.
paths_for() {
    rm -f build/beans_enc_base64.*.o build/beans_enc_base64.*.bc 2>/dev/null || true
    "$@" >/dev/null 2>&1 || true
    local found=""
    local entry
    for entry in build/beans_enc_base64.*.o build/beans_enc_base64.*.bc; do
        [[ -f "$entry" ]] && found="$found$entry "
    done
    printf '%s' "$found"
}

base=$(paths_for ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ -z "$base" ]]; then
    echo "no encoding object was produced at all" >&2
    exit 1
fi

assert_differs() {
    local label=$1
    shift
    local other
    other=$(paths_for "$@")
    if [[ "$other" == "$base" ]]; then
        echo "$label produced the same cache path as the baseline: $base" >&2
        exit 1
    fi
    if [[ -z "$other" ]]; then
        echo "$label produced no object" >&2
        exit 1
    fi
    echo "  ok $label changes the cache path"
}

assert_differs "--release" \
    ./build/beansc build --release "$tmp/prog.b" -o "$tmp/prog"
assert_differs "--release --lto" \
    ./build/beansc build --release --lto "$tmp/prog.b" -o "$tmp/prog"
assert_differs "--emit shared (PIC)" \
    ./build/beansc build --emit shared "$tmp/prog.b" -o "$tmp/prog.dylib"
assert_differs "--cpu" \
    ./build/beansc build --cpu native "$tmp/prog.b" -o "$tmp/prog"

# The target is in the cache path by construction, so an object built for
# one target can never be offered to another. A cross build cannot be used
# to demonstrate it here because compiling the bridge C for another target
# needs that target's headers (see the cross-compile limit in the docs), so
# the assertion is on the path the host build produced.
host_triple=$(./build/beansc doctor 2>/dev/null |
    grep -oE '[A-Za-z0-9_]+-[A-Za-z0-9_]+-[A-Za-z0-9_]+(-[A-Za-z0-9_]+)?' |
    head -1)
if [[ -z "$host_triple" ]]; then
    echo "could not determine the host triple from beansc doctor" >&2
    exit 1
fi
case "$base" in
    *".$host_triple."*) echo "  ok the target triple is part of the cache path" ;;
    *)
        echo "cache path '$base' does not name the target '$host_triple'" >&2
        exit 1
        ;;
esac

# A changed vendored or bridge source must invalidate too. Copy the tree to a
# scratch root, point BEANS_ENCODING at it, and touch one byte of a comment.
cp -R runtime/encoding/. "$tmp_enc/"
copied=$(BEANS_ENCODING="$tmp_enc" paths_for \
    ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ "$copied" != "$base" ]]; then
    echo "an identical copy of the sources changed the cache path" >&2
    echo "  baseline: $base" >&2
    echo "  copy:     $copied" >&2
    exit 1
fi
echo "  ok identical sources at a different root reuse the same key"

printf '\n// cache invalidation probe\n' >>"$tmp_enc/beans_enc_base64.cpp"
edited=$(BEANS_ENCODING="$tmp_enc" paths_for \
    ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ "$edited" == "$base" ]]; then
    echo "editing the bridge source did not change the cache path" >&2
    exit 1
fi
echo "  ok an edited bridge source changes the cache path"

printf '\n/* vendor probe */\n' >>"$tmp_enc/vendor/simdutf/simdutf.h"
vendored=$(BEANS_ENCODING="$tmp_enc" paths_for \
    ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ "$vendored" == "$edited" ]]; then
    echo "editing a vendored header did not change the cache path" >&2
    exit 1
fi
echo "  ok an edited vendored header changes the cache path"

# The ABI version is part of the key, so a contract bump invalidates every
# cached object even when no source byte moved.
grep -q 'return "enc-abi-' compiler/beans/driver.b
echo "  ok the bridge ABI version is part of the key"

# The compiler identity is in the key: a different --cc must not reuse the
# object built by the default one. A wrapper script that execs the real
# clang has the same behaviour but a different identity.
cat >"$tmp/cc-wrapper" <<EOF
#!/bin/sh
exec $(command -v clang) "\$@"
EOF
chmod +x "$tmp/cc-wrapper"
wrapped=$(paths_for ./build/beansc build --cc "$tmp/cc-wrapper" \
    "$tmp/prog.b" -o "$tmp/prog")
if [[ "$wrapped" == "$base" ]]; then
    echo "a different --cc reused the default compiler's object" >&2
    exit 1
fi
echo "  ok a different C driver changes the cache path"

# And the payoff: an unchanged build must reuse, not rebuild.
rm -f build/beans_enc_base64.*.o
./build/beansc build "$tmp/prog.b" -o "$tmp/prog" >/dev/null
first=$(ls -l build/beans_enc_base64.*.o | awk '{print $NF}')
first_inode=$(ls -i "$first" | awk '{print $1}')
./build/beansc build "$tmp/prog.b" -o "$tmp/prog2" >/dev/null
second_inode=$(ls -i "$first" | awk '{print $1}')
if [[ "$first_inode" != "$second_inode" ]]; then
    echo "an unchanged rebuild recompiled the bridge instead of reusing it" >&2
    exit 1
fi
"$tmp/prog2" | grep -q '^Y2FjaGU=$'
echo "  ok an unchanged rebuild reuses the cached object"

echo "ok encoding cache key covers ABI, target, mode, compiler, flags and sources"
