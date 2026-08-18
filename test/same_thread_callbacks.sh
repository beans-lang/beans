#!/usr/bin/env bash
# G7: StoredCallback.create_same_thread — captures unrestricted (no
# Send+Sync), every invocation checked against the registering thread,
# cross-thread invocation is a runtime abort. Same close() discipline.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/same_fixture.c" <<'C'
#include <pthread.h>
#include <stdint.h>
typedef int32_t (*same_fn)(void*, int32_t);
static same_fn callback;
static void* context;
void same_register(same_fn function, void* value) {
    callback = function;
    context = value;
}
void same_unregister(void) { callback = 0; context = 0; }
int32_t same_invoke_here(int32_t value) {
    return callback(context, value);
}
static void* worker(void* raw) {
    int32_t* value = raw;
    *value = callback(context, *value);
    return 0;
}
int32_t same_invoke_worker(int32_t value) {
    pthread_t thread;
    pthread_create(&thread, 0, worker, &value);
    pthread_join(thread, 0);
    return value;
}
C
if [[ $(uname -s) == Darwin ]]; then
    clang -dynamiclib -pthread "$tmp/same_fixture.c" -o "$tmp/libsame_fixture.dylib"
else
    clang -shared -fPIC -pthread "$tmp/same_fixture.c" -o "$tmp/libsame_fixture.so"
fi
write_program() {
    local dir=$1
    local tail=$2
    mkdir -p "$tmp/$dir"
    cat >"$tmp/$dir/beans.pot" <<MOD
module same_$dir
link all search ".."
link all library "same_fixture"
MOD
    cat >"$tmp/$dir/main.b" <<BEANS
package main

import std.io

extern "C" fn register(
    callback: fn(RawPtr<u8>, i32) -> i32,
    context: RawPtr<u8>
) as "same_register"
extern "C" fn unregister() as "same_unregister"
extern "C" fn invoke_here(value: i32) -> i32 as "same_invoke_here"
extern "C" fn invoke_worker(value: i32) -> i32 as "same_invoke_worker"

class Tally {
    hits: int = 0
}

fn main() {
    // a plain class object is neither Send nor Sync: the same-thread
    // flavor may capture it anyway
    let tally: Tally = new Tally()
    var callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create_same_thread(0, fn(value: i32) -> i32 {
            tally.hits = tally.hits + 1
            return value + (tally.hits as i32)
        })
    unsafe {
        register(callback.function(), callback.context())
        io.println("first {invoke_here(10)}")
        io.println("second {invoke_here(10)}")
        io.println("hits {tally.hits}")
        $tail
        unregister()
    }
    callback.close()
    io.println("closed")
}
BEANS
}

write_program ok ''
write_program cross 'io.println("cross {invoke_worker(10)}")'

run_ok() {
    local label=$1; shift
    "$@" >"$tmp/out" 2>&1
    grep -Fqx "first 11" "$tmp/out"
    grep -Fqx "second 12" "$tmp/out"
    grep -Fqx "hits 2" "$tmp/out"
    grep -Fqx "closed" "$tmp/out"
    echo "ok $label"
}

run_cross() {
    local label=$1; shift
    if "$@" >"$tmp/cross.out" 2>&1; then
        echo "cross-thread call unexpectedly survived ($label)" >&2
        exit 1
    fi
    grep -q "same-thread stored callback invoked from another thread" "$tmp/cross.out"
    echo "ok $label cross abort"
}

export BEANS_RUNTIME="$root/runtime/beans_rt.c"
cd "$tmp/ok"
run_ok interp "$beansc" run main.b
"$beansc" build main.b -o same_ok.bin >/dev/null
run_ok native ./same_ok.bin
cd "$tmp/cross"
run_cross interp "$beansc" run main.b
"$beansc" build main.b -o same_cross.bin >/dev/null
run_cross native ./same_cross.bin
cd "$tmp"

# the Sync restriction still guards the any-thread flavor
cat >"$tmp/still_sync.b" <<'BEANS'
package main

class Tally {
    hits: int = 0
}

fn main() {
    let tally: Tally = new Tally()
    let callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create(0, fn(value: i32) -> i32 {
            tally.hits = tally.hits + 1
            return value
        })
    callback.close()
}
BEANS
if "$beansc" check still_sync.b >"$tmp/sync.out" 2>&1; then
    echo "any-thread StoredCallback lost its Sync capture rule" >&2
    exit 1
fi
grep -q "non-Sync" "$tmp/sync.out"

echo "ok same-thread stored callbacks"
