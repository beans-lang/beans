#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-stdlib-source.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

assert_beans_function() {
    local name=$1
    local result=$2
    local file=$3
    awk -v name="$name" -v result="$result" '
        index($0, "; " name) == 1 {
            getline
            if (index($0, "define " result " @") == 1) found = 1
        }
        END { exit !found }
    ' "$file"
}

echo "checking compiler-shipped Beans std packages"
./build/beansc run examples/stdlib_beans.b >"$tmp/interp"
./build/beansc build examples/stdlib_beans.b -o "$tmp/native" >"$tmp/build"
"$tmp/native" >"$tmp/native.out"

diff -u test/cases/stdlib_beans.out "$tmp/interp"
diff -u test/cases/stdlib_beans.out "$tmp/native.out"
assert_beans_function path.join ptr build/stdlib_beans.ll
assert_beans_function fmt.hex ptr build/stdlib_beans.ll
assert_beans_function fmt.bin ptr build/stdlib_beans.ll
assert_beans_function fmt.group ptr build/stdlib_beans.ll
assert_beans_function 'collections.increment$' i64 build/stdlib_beans.ll
assert_beans_function 'collections.map_values$' ptr build/stdlib_beans.ll
grep -Eq 'define internal i64 @[^ (]*eq[^(]*[(]' build/stdlib_beans.ll
if grep -Eq 'beans_path_|beans_fmt_(hex|bin|group)' build/beans_rt.c; then
    echo "migrated path/fmt code still exists in the native runtime" >&2
    exit 1
fi

./build/beansc build bench/bytes.b -o "$tmp/bytes" >"$tmp/bytes-build"
assert_beans_function bytes.append_varint void build/bytes.ll
assert_beans_function bytes.decode_varint_at_or i64 build/bytes.ll
assert_beans_function bytes.crc32 i32 build/bytes.ll
if grep -Eq 'call .*@beans_bytes_(append_varint|get_varint|crc32)' build/bytes.ll; then
    echo "bytes benchmark still calls migrated native algorithms" >&2
    exit 1
fi

echo "ok Beans collection policies, Option/Result methods, math, bytes, path, and fmt packages"
