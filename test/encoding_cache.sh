#!/usr/bin/env bash
set -euo pipefail

# The encoding object cache must never hand back an object built for a
# different contract. Each case below changes exactly one input and asserts
# the cache path changes with it; the last case asserts an unchanged build
# reuses its object rather than rebuilding.
#
# Every build here must succeed. A build that fails produces no object, and
# "no object" would otherwise read as "a different object" and pass a test
# that proved nothing — so build failures are fatal and their output is
# printed.

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-cache.XXXXXX")
tmp_enc=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-src.XXXXXX")
tmp_cc=$(mktemp -d "${TMPDIR:-/tmp}/beans-enc-cc.XXXXXX")
trap 'rm -rf "$tmp" "$tmp_enc" "$tmp_cc"' EXIT

echo "checking the encoding bridge cache key"

cat >"$tmp/prog.b" <<'EOF'
import std.io
import std.encoding.base64

fn main() {
    io.println(base64.encode(Bytes.from("cache")))
}
EOF

# Clears the cache, runs one build, and reports the cache path it settled
# on. The build MUST exit 0 and MUST leave exactly one object behind.
paths_for() {
    local label=$1
    shift
    rm -f build/beans_enc_base64.*.o build/beans_enc_base64.*.bc 2>/dev/null || true
    if ! "$@" >"$tmp/build.log" 2>&1; then
        echo "build failed for case '$label':" >&2
        sed -n '1,40p' "$tmp/build.log" >&2
        exit 1
    fi
    local found=""
    local count=0
    local entry
    for entry in build/beans_enc_base64.*.o build/beans_enc_base64.*.bc; do
        if [[ -f "$entry" ]]; then
            found="$found$entry "
            count=$((count + 1))
        fi
    done
    if [[ "$count" -ne 1 ]]; then
        echo "case '$label' produced $count encoding objects, expected 1" >&2
        exit 1
    fi
    printf '%s' "$found"
}

base=$(paths_for baseline ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")

assert_differs() {
    local label=$1
    shift
    local other
    other=$(paths_for "$label" "$@")
    if [[ "$other" == "$base" ]]; then
        echo "$label produced the same cache path as the baseline: $base" >&2
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
# one target can never be offered to another. A cross build cannot
# demonstrate it here because compiling the bridge C for another target
# needs that target's headers, so the assertion is on the path the host
# build produced.
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

# ---- source contents ----
cp -R runtime/encoding/. "$tmp_enc/"
copied=$(BEANS_ENCODING="$tmp_enc" paths_for "identical copy" \
    ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ "$copied" != "$base" ]]; then
    echo "an identical copy of the sources changed the cache path" >&2
    echo "  baseline: $base" >&2
    echo "  copy:     $copied" >&2
    exit 1
fi
echo "  ok identical sources at a different root reuse the same key"

printf '\n// cache invalidation probe\n' >>"$tmp_enc/beans_enc_base64.cpp"
edited=$(BEANS_ENCODING="$tmp_enc" paths_for "edited bridge source" \
    ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ "$edited" == "$base" ]]; then
    echo "editing the bridge source did not change the cache path" >&2
    exit 1
fi
echo "  ok an edited bridge source changes the cache path"

printf '\n/* vendor probe */\n' >>"$tmp_enc/vendor/simdutf/simdutf.h"
vendored=$(BEANS_ENCODING="$tmp_enc" paths_for "edited vendored header" \
    ./build/beansc build "$tmp/prog.b" -o "$tmp/prog")
if [[ "$vendored" == "$edited" ]]; then
    echo "editing a vendored header did not change the cache path" >&2
    exit 1
fi
echo "  ok an edited vendored header changes the cache path"

# ---- bridge ABI version ----
# Really bump it: rebuild a compiler whose encoding_bridge_abi() returns a
# different string and check the object it asks for moves. Nothing else in
# the tree changes, so the ABI version is the only possible cause.
abi_now=$(grep -oE 'return "enc-abi-[0-9]+"' compiler/beans/driver.b | head -1)
if [[ -z "$abi_now" ]]; then
    echo "could not find the bridge ABI version in compiler/beans/driver.b" >&2
    exit 1
fi
mkdir -p "$tmp/abi"
cp -R compiler "$tmp/abi/compiler"
sed -i.bak 's/return "enc-abi-[0-9]*"/return "enc-abi-999999"/' \
    "$tmp/abi/compiler/beans/driver.b"
if ! grep -q 'enc-abi-999999' "$tmp/abi/compiler/beans/driver.b"; then
    echo "the ABI bump did not apply to the copied compiler source" >&2
    exit 1
fi
if ! ./build/beansc build "$tmp/abi/compiler/beans/main.b" \
    -o "$tmp/beansc-abi" >"$tmp/abi.log" 2>&1; then
    echo "could not build a compiler with a bumped bridge ABI version:" >&2
    sed -n '1,40p' "$tmp/abi.log" >&2
    exit 1
fi
bumped=$(paths_for "bumped ABI version" "$tmp/beansc-abi" build \
    "$tmp/prog.b" -o "$tmp/prog")
if [[ "$bumped" == "$base" ]]; then
    echo "a bumped bridge ABI version reused the old object: $base" >&2
    exit 1
fi
echo "  ok a bumped bridge ABI version ($abi_now -> enc-abi-999999) changes the cache path"

# ---- compiler identity ----
# Not just a different path: a driver reporting a different --version must
# invalidate, because that is what a toolchain upgrade looks like. The
# wrapper compiles with the real clang but reports a version of its own.
real_cc=$(command -v "${BEANS_CC:-clang}")
cat >"$tmp_cc/clang" <<EOF
#!/bin/sh
for argument in "\$@"; do
    if [ "\$argument" = "--version" ]; then
        echo "beans test clang version 99.0.0 (pretend-toolchain)"
        exit 0
    fi
done
exec "$real_cc" "\$@"
EOF
chmod +x "$tmp_cc/clang"
"$tmp_cc/clang" --version | grep -q "99.0.0"
versioned=$(paths_for "changed compiler version" ./build/beansc build \
    --cc "$tmp_cc/clang" "$tmp/prog.b" -o "$tmp/prog")
if [[ "$versioned" == "$base" ]]; then
    echo "a compiler reporting a different version reused the old object" >&2
    exit 1
fi
echo "  ok a compiler reporting a different version changes the cache path"

# A second wrapper at a different path but reporting the *same* fake
# version must differ from the first only because its path differs, which
# proves the path is in the key too.
mkdir -p "$tmp_cc/second"
cp "$tmp_cc/clang" "$tmp_cc/second/clang"
second=$(paths_for "same version, different path" ./build/beansc build \
    --cc "$tmp_cc/second/clang" "$tmp/prog.b" -o "$tmp/prog")
if [[ "$second" == "$versioned" ]]; then
    echo "two different compiler paths shared one cache path" >&2
    exit 1
fi
echo "  ok the compiler path is part of the cache path"

# ---- reuse ----
rm -f build/beans_enc_base64.*.o
./build/beansc build "$tmp/prog.b" -o "$tmp/prog" >/dev/null
first=$(ls build/beans_enc_base64.*.o)
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
