#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-log.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking std.log"

./build/beansc run test/cases/log_basic.b >"$tmp/interp"
./build/beansc build test/cases/log_basic.b -o "$tmp/native" >/dev/null
"$tmp/native" >"$tmp/native.out"
./build/beansc build --release --lto test/cases/log_basic.b \
    -o "$tmp/native-lto" >/dev/null
"$tmp/native-lto" >"$tmp/native-lto.out"
diff -u test/expected/log_basic.txt "$tmp/interp"
diff -u test/expected/log_basic.txt "$tmp/native.out"
diff -u test/expected/log_basic.txt "$tmp/native-lto.out"

./build/beansc run test/cases/log_levels.b >"$tmp/levels.interp"
./build/beansc build test/cases/log_levels.b \
    -o "$tmp/levels.native" >/dev/null
"$tmp/levels.native" >"$tmp/levels.native.out"
diff -u test/expected/log_levels.txt "$tmp/levels.interp"
diff -u test/expected/log_levels.txt "$tmp/levels.native.out"

# Mixed MSVC jobs cannot build the GNU bootstrap interpreter's C++ bridge
# from an MSVC-only environment. They still run logging.exe and compare it to
# this tracked output, so keep the fixture tied to the normal interpreter.
./build/beansc run examples/logging.b >"$tmp/example.interp"
diff -u test/cases/logging.out "$tmp/example.interp"
grep -q 'examples/logging\.b) fixture=test/cases/logging\.out' \
    test/windows_native_stage.sh
echo "ok interpreter/native parity and source metadata"

# The shipped private helper is a native intrinsic. It must borrow string
# payloads and their O(1) lengths, not copy them through Bytes first.
grep -q 'call i64 @beans_log_write' build/log_basic.ll
grep -q '%log.msg.len' build/log_basic.ll
grep -q 'c"test/cases/log_basic.b\\00"' build/log_basic.ll
grep -q 'c"main.run\\00"' build/log_basic.ll
echo "ok native logging uses the direct string fast path"

./build/beansc build --runtime minimal test/cases/log_basic.b \
    -o "$tmp/minimal" >/dev/null
"$tmp/minimal" >"$tmp/minimal.out"
diff -u test/expected/log_basic.txt "$tmp/minimal.out"

./build/beansc build --runtime minimal test/cases/log_minimal_file.b \
    -o "$tmp/minimal-file" >/dev/null
"$tmp/minimal-file" >"$tmp/minimal-file.out"
diff -u test/expected/log_minimal_file.txt "$tmp/minimal-file.out"

if ./build/beansc check --runtime freestanding test/cases/profile_log.b \
        >"$tmp/freestanding" 2>&1; then
    echo "std.log was accepted by the freestanding profile" >&2
    exit 1
fi
grep -qF "'std.log' needs threads, which the freestanding runtime does not have" \
    "$tmp/freestanding"
echo "ok full/minimal support and freestanding refusal"

# A program pays for Quill only when it imports std.log.
./build/beansc build examples/hello.b -o "$tmp/hello" >/dev/null
nm "$tmp/hello" >"$tmp/hello.syms"
if grep -Eq 'beans_log_|quill' "$tmp/hello.syms"; then
    echo "a program without std.log contains logging symbols" >&2
    exit 1
fi
nm "$tmp/native" >"$tmp/log.syms"
grep -q 'beans_log_write' "$tmp/log.syms"
./build/beansc build --emit shared test/cases/profile_log.b \
    -o "$tmp/profile-log.dylib" >/dev/null
./build/beansc build --emit static test/cases/profile_log.b \
    -o "$tmp/profile-log.a" >/dev/null
nm "$tmp/profile-log.dylib" >"$tmp/profile-log.shared.syms"
nm "$tmp/profile-log.a" >"$tmp/profile-log.static.syms"
grep -q beans_log_write "$tmp/profile-log.shared.syms"
grep -q beans_log_write "$tmp/profile-log.static.syms"
echo "ok import-only native bridge linkage"

# The native bridge cache is content addressed: moving an identical source
# tree reuses the key, while either Beans bridge code or a Quill header changes
# it. Work in the temporary directory so this never clears a developer cache.
repo=$PWD
mkdir "$tmp/cache-work" "$tmp/log-copy"
cp -R runtime/log/. "$tmp/log-copy/"
cache_path() {
    local source_root=$1
    (
        cd "$tmp/cache-work"
        rm -f build/beans_log.*.o build/beans_log.*.bc 2>/dev/null || true
        BEANS_RUNTIME="$repo/runtime/beans_rt.c" \
        BEANS_STDLIB="$repo/stdlib/std" \
        BEANS_LOG="$source_root" \
            "$repo/build/beansc" build "$repo/test/cases/profile_log.b" \
            -o "$tmp/cache-program" >/dev/null
        find build -maxdepth 1 -type f \
            \( -name 'beans_log.*.o' -o -name 'beans_log.*.bc' \) -print
    )
}
base_cache=$(cache_path "$repo/runtime/log")
copy_cache=$(cache_path "$tmp/log-copy")
if [[ "$copy_cache" != "$base_cache" ]]; then
    echo "moving identical std.log sources changed the cache key" >&2
    exit 1
fi
printf '\n// cache invalidation probe\n' >>"$tmp/log-copy/beans_log.cpp"
bridge_cache=$(cache_path "$tmp/log-copy")
if [[ "$bridge_cache" == "$base_cache" ]]; then
    echo "editing beans_log.cpp did not change the cache key" >&2
    exit 1
fi
printf '\n// cache invalidation probe\n' \
    >>"$tmp/log-copy/vendor/quill/include/quill/Backend.h"
vendor_cache=$(cache_path "$tmp/log-copy")
if [[ "$vendor_cache" == "$bridge_cache" ]]; then
    echo "editing a Quill header did not change the cache key" >&2
    exit 1
fi
echo "ok content-addressed bridge cache invalidation"

# Lock the C/Beans contract as a set. Adding one side without the other must
# fail here instead of surfacing as a platform-only missing symbol later.
perl -0777 -ne '
    while (/BEANS_LOG_API\s+[^;{}]*?\b(beans_log_[A-Za-z0-9_]+)\s*\(/sg) {
        print "$1\n";
    }
' runtime/log/beans_log.h | sort -u >"$tmp/c.exports"
perl -0777 -ne '
    while (/extern\s+"C"\s+fn\s+(beans_log_[A-Za-z0-9_]+)\s*\(/sg) {
        print "$1\n";
    }
' stdlib/std/log/log.b | sort -u >"$tmp/beans.externs"
diff -u "$tmp/c.exports" "$tmp/beans.externs"
echo "ok C and Beans API inventories match"

# Exercise the bridge itself so file and NDJSON formatting do not hide behind
# the higher-level export-only parity case.
cxx=${CXX:-clang++}
"$cxx" -std=c++17 -O2 -fno-rtti -pthread \
    -DBEANS_RT_PROFILE=3 \
    -Iruntime/log -Iruntime/log/vendor/quill/include \
    runtime/log/beans_log.cpp test/log_bridge.cpp \
    -o "$tmp/bridge-test"
mkdir "$tmp/bridge-output"
"$tmp/bridge-test" "$tmp/bridge-output"
echo "ok console/file/NDJSON/export bridge contract"

echo "ok std.log"
