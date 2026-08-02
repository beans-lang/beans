#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/access_globals.c" <<'C'
#include <stdint.h>
int32_t access_version = 7;
int32_t access_counter = 10;
_Thread_local int32_t access_thread_counter = 1;
C
if [[ $(uname -s) == Darwin ]]; then
    clang -dynamiclib "$tmp/access_globals.c" -o "$tmp/libaccess_globals.dylib"
    preload=DYLD_INSERT_LIBRARIES
    library_path=DYLD_LIBRARY_PATH
else
    clang -shared -fPIC "$tmp/access_globals.c" -o "$tmp/libaccess_globals.so"
    preload=LD_PRELOAD
    library_path=LD_LIBRARY_PATH
fi

cat >"$tmp/beans.pot" <<'MOD'
module access_globals
link all search "."
link all library "access_globals"
MOD
cat >"$tmp/main.b" <<'BEANS'
import std.c
import std.io
import std.thread

extern "C" let version: i32 as "access_version"
extern "C" var counter: i32 as "access_counter"
extern "C" thread_local var thread_counter: i32 as "access_thread_counter"

fn main() {
    unsafe {
        io.println(version)
        io.println(counter)
        io.println(thread_counter)
        counter = 42
        thread_counter = 9
        io.println(counter)
        io.println(thread_counter)
    }
    let worker: Thread<i32> = thread.spawn(fn() -> i32 {
        unsafe {
            thread_counter = 25
            return thread_counter
        }
    })
    io.println(worker.join())
    unsafe {
        io.println(thread_counter)
    }
    // errno may be changed by the host calls used to create and join a thread.
    // Test the setter and getter together instead of asserting that two
    // different backend implementations preserve it across unrelated work.
    c.set_errno(37)
    io.println(c.errno())
}
BEANS
if ! env "$preload=$tmp/libaccess_globals.$([[ $(uname -s) == Darwin ]] && echo dylib || echo so)" \
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
cat >"$tmp/expected" <<'OUT'
7
10
1
42
9
25
9
37
OUT
diff -u "$tmp/expected" "$tmp/native.out"

echo "c globals tls errno ok"
