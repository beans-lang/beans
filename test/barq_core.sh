#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc="$root/build/beansc"
commit=b5b3f76c85b981c4532409589b28b8507022e15e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ "$(uname -s):$(uname -m)" != "Linux:x86_64" ]]; then
    echo "Barq Core integration requires Linux x86-64" >&2
    exit 2
fi

if [[ -n "${BARQ_CORE_DIR:-}" ]]; then
    barq=$(cd "$BARQ_CORE_DIR" && pwd)
    actual=$(git -C "$barq" rev-parse HEAD)
    if [[ "$actual" != "$commit" ]]; then
        echo "BARQ_CORE_DIR is at $actual, expected $commit" >&2
        exit 1
    fi
else
    barq="$tmp/barq-core"
    git init -q "$barq"
    git -C "$barq" remote add origin https://github.com/BarqDB/barq-core.git
    git -C "$barq" fetch -q --depth 1 origin "$commit"
    git -C "$barq" checkout -q --detach FETCH_HEAD
    git -C "$barq" submodule update -q --init --recursive --depth 1
fi

barq_build="$tmp/barq-build"
cmake -S "$barq" -B "$barq_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBARQ_ENABLE_SYNC=ON \
    -DBARQ_ENABLE_GEOSPATIAL=ON \
    -DBARQ_ENABLE_ENCRYPTION=ON \
    -DBARQ_BUILD_LIB_ONLY=ON \
    -DBARQ_NO_TESTS=ON \
    -DBARQ_USE_SYSTEM_OPENSSL=ON
cmake --build "$barq_build" --target BarqFFI --parallel 2

barq_library=$(find "$barq_build" -type f -name 'libbarq-ffi.so' -print -quit)
if [[ -z "$barq_library" ]]; then
    echo "BarqFFI did not produce libbarq-ffi.so" >&2
    exit 1
fi

project="$tmp/beans-barq"
mkdir -p "$project/native/lib"
cp "$barq_library" "$project/native/lib/"

# The bindings land in a beans.pot project beside main.b, so they are a file in
# that package and have to say so — a generated file with no package clause only
# loads on its own.
"$beansc" bindgen "$barq/src/barq.h" -o "$project/barq_bindings.b" \
    --package main \
    --only barq_get_library_version_numbers \
    --only barq_config_new \
    --only barq_config_set_in_memory \
    --only barq_release \
    -- -I"$barq/src"

cat >"$project/beans.pot" <<'MOD'
module beans_barq
link all search "native/lib"
link all library "barq-ffi"
MOD
cat >"$project/main.b" <<'BEANS'
package main

import std.io

fn main() {
    var major: i32 = 0
    var minor: i32 = 0
    var patch: i32 = 0
    unsafe {
        var extra: RawPtr<i8> = RawPtr.null()
        RawPtr.with_local(inout major, fn(major_pointer: RawPtr<i32>) {
            RawPtr.with_local(inout minor, fn(minor_pointer: RawPtr<i32>) {
                RawPtr.with_local(inout patch, fn(patch_pointer: RawPtr<i32>) {
                    RawPtr.with_local(inout extra, fn(extra_pointer: RawPtr<RawPtr<i8>>) {
                        barq_get_library_version_numbers(
                            major_pointer, minor_pointer, patch_pointer,
                            extra_pointer)
                    })
                })
            })
        })

        let config: RawPtr<BarqConfigT> = barq_config_new()
        if config.is_null() {
            return
        }
        barq_config_set_in_memory(config, true)
        let released: RawPtr<u8> =
            RawPtr.from_address(config.address())
        barq_release(released)
    }
    io.println("{major}.{minor}.{patch}")
}
BEANS

"$beansc" check "$project/main.b"
"$beansc" build "$project/main.b" -o "$project/barq_smoke"
LD_LIBRARY_PATH="$project/native/lib" "$project/barq_smoke" \
    >"$project/output"
grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "$project/output" >/dev/null

echo "Barq Core integration ok"
