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
assert_beans_function std.path.join ptr build/stdlib_beans.ll
assert_beans_function std.fmt.hex ptr build/stdlib_beans.ll
assert_beans_function std.fmt.binary ptr build/stdlib_beans.ll
assert_beans_function std.fmt.group_digits ptr build/stdlib_beans.ll
assert_beans_function 'std.collections.increment$' i64 build/stdlib_beans.ll
assert_beans_function 'std.collections.map_values_with_key$' ptr build/stdlib_beans.ll
grep -Eq 'define internal i64 @[^ (]*eq[^(]*[(]' build/stdlib_beans.ll
if grep -Eq 'beans_path_|beans_fmt_(hex|bin|group)' build/beans_rt.c; then
    echo "migrated path/fmt code still exists in the native runtime" >&2
    exit 1
fi

./build/beansc build bench/bytes.b -o "$tmp/bytes" >"$tmp/bytes-build"
assert_beans_function std.bytes.append_uvarint void build/bytes.ll
assert_beans_function std.bytes.decode_uvarint_at_or i64 build/bytes.ll
assert_beans_function std.bytes.crc32 i32 build/bytes.ll
if grep -Eq 'call .*@beans_bytes_(append_varint|get_varint|crc32)' build/bytes.ll; then
    echo "bytes benchmark still calls migrated native algorithms" >&2
    exit 1
fi

echo "ok Beans collection policies, Option/Result methods, math, bytes, path, and fmt packages"
