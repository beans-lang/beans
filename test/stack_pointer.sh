#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/stack_fixture.c" <<'C'
#include <stdint.h>
void stack_bump(int32_t* value) { *value += 5; }
C
if [[ $(uname -s) == Darwin ]]; then
    clang -dynamiclib "$tmp/stack_fixture.c" -o "$tmp/libstack_fixture.dylib"
    preload=DYLD_INSERT_LIBRARIES
    library_path=DYLD_LIBRARY_PATH
else
    clang -shared -fPIC "$tmp/stack_fixture.c" -o "$tmp/libstack_fixture.so"
    preload=LD_PRELOAD
    library_path=LD_LIBRARY_PATH
fi
cat >"$tmp/beans.pot" <<'MOD'
module stack_pointer
link all search "."
link all library "stack_fixture"
MOD
cat >"$tmp/main.b" <<'BEANS'
import std.io
extern "C" fn bump(value: RawPtr<i32>) as "stack_bump"
fn main() {
    var value: i32 = 37
    var nested: i32 = 10
    unsafe {
        RawPtr.with_local(inout value, fn(pointer: RawPtr<i32>) {
            RawPtr.with_local(inout nested, fn(nested_pointer: RawPtr<i32>) {
                bump(pointer)
                bump(nested_pointer)
            })
        })
    }
    io.println("{value} {nested}")
}
BEANS
extension=$([[ $(uname -s) == Darwin ]] && echo dylib || echo so)
if ! env "$preload=$tmp/libstack_fixture.$extension" \
    "$beansc" run "$tmp/main.b" >"$tmp/interp" 2>&1; then
    cat "$tmp/interp" >&2
    exit 1
fi
if ! "$beansc" build "$tmp/main.b" -o "$tmp/native" \
    >"$tmp/build.out" 2>&1; then
    cat "$tmp/build.out" >&2
    exit 1
fi
env "$library_path=$tmp" "$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"
grep -Fx '42 15' "$tmp/native.out" >"$tmp/match"

echo "stack pointer and captured nested inout ok"
