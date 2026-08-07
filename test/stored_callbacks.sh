#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
if [[ "${BEANS_KEEP_TEST_TMP:-0}" == "1" ]]; then
    trap 'echo "kept callback test files in $tmp" >&2' EXIT
else
    trap 'rm -rf "$tmp"' EXIT
fi

cat >"$tmp/stored_fixture.c" <<'C'
#include <pthread.h>
#include <stdint.h>
typedef int32_t (*stored_fn)(void*, int32_t);
static stored_fn callback;
static void* context;
void stored_register(stored_fn function, void* value) {
    callback = function;
    context = value;
}
void stored_unregister(void) {
    callback = 0;
    context = 0;
}
static void* worker(void* raw) {
    int32_t* value = raw;
    *value = callback(context, *value);
    return 0;
}
int32_t stored_fire(int32_t value) {
    pthread_t thread;
    pthread_create(&thread, 0, worker, &value);
    pthread_join(thread, 0);
    return value;
}
C
if [[ $(uname -s) == Darwin ]]; then
    clang -dynamiclib -pthread "$tmp/stored_fixture.c" -o "$tmp/libstored_fixture.dylib"
    preload=DYLD_INSERT_LIBRARIES
    library_path=DYLD_LIBRARY_PATH
else
    clang -shared -fPIC -pthread "$tmp/stored_fixture.c" -o "$tmp/libstored_fixture.so"
    preload=LD_PRELOAD
    library_path=LD_LIBRARY_PATH
fi
cat >"$tmp/beans.pot" <<'MOD'
module stored_callbacks
link all search "."
link all library "stored_fixture"
MOD
cat >"$tmp/main.b" <<'BEANS'
package main

import std.io
extern "C" fn register(
    callback: fn(RawPtr<u8>, i32) -> i32,
    context: RawPtr<u8>
) as "stored_register"
extern "C" fn unregister() as "stored_unregister"
extern "C" fn fire(value: i32) -> i32 as "stored_fire"
fn main() {
    let callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create(0, fn(value: i32) -> i32 {
            return value + 1
        })
    unsafe {
        register(callback.function(), callback.context())
        io.println(fire(41))
        unregister()
    }
    callback.close()
}
BEANS
extension=$([[ $(uname -s) == Darwin ]] && echo dylib || echo so)
if ! env "$preload=$tmp/libstored_fixture.$extension" \
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
grep -Fx '42' "$tmp/native.out" >"$tmp/match"

cat >"$tmp/closed_twice.b" <<'BEANS'
package main

fn bad() {
    let callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create(0, fn(value: i32) -> i32 { return value })
    callback.close()
    callback.close()
}
BEANS
if "$beansc" check "$tmp/closed_twice.b" >"$tmp/closed_twice.out" 2>&1; then
    echo "a closed StoredCallback stayed usable" >&2
    exit 1
fi
grep -F 'use of moved value' "$tmp/closed_twice.out" >/dev/null

if [[ "${BEANS_SANITIZE_CALLBACKS:-0}" == "1" ]]; then
    clang -O1 -g -pthread -fsanitize=address,undefined \
        -fno-sanitize-recover=undefined -Wno-override-module \
        build/main.ll build/main_ffi.c build/beans_rt.c \
        "$tmp/stored_fixture.c" -lm -o "$tmp/stored_asan"
    BEANS_NO_POOL=1 "$tmp/stored_asan" >"$tmp/asan.out" \
        2>"$tmp/asan.err"
    if grep -Eq 'AddressSanitizer|runtime error:' "$tmp/asan.err"; then
        sed -n '1,160p' "$tmp/asan.err" >&2
        exit 1
    fi

    if clang -O1 -g -pthread -fsanitize=thread \
        -Wno-override-module build/main.ll build/main_ffi.c \
        build/beans_rt.c "$tmp/stored_fixture.c" -lm \
        -o "$tmp/stored_tsan"; then
        set +e
        BEANS_NO_POOL=1 "$tmp/stored_tsan" >"$tmp/tsan.out" \
            2>"$tmp/tsan.err"
        tsan_status=$?
        set -e
        if grep -q 'WARNING: ThreadSanitizer' "$tmp/tsan.err"; then
            sed -n '1,200p' "$tmp/tsan.err" >&2
            exit 1
        fi
        if ! grep -q 'ThreadSanitizer: CHECK failed' "$tmp/tsan.err" &&
           [[ "$tsan_status" -ne 0 ]]; then
            sed -n '1,100p' "$tmp/tsan.err" >&2
            exit 1
        fi
    fi
fi

echo "stored callbacks ok"
