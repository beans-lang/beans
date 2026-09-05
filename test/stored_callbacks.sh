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
#include <stddef.h>
#include <stdint.h>
typedef int32_t (*stored_fn)(void*, int32_t);
typedef struct stored_slot {
    stored_fn function;
    void* context;
} stored_slot;
static stored_fn callback;
static void* context;
static int32_t stored_add_two(void* ignored, int32_t value) {
    (void)ignored;
    return value + 2;
}
stored_fn stored_global_function = stored_add_two;
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
stored_slot stored_make_slot(stored_fn function, void* value) {
    stored_slot slot = {function, value};
    return slot;
}
int32_t stored_call_slot(stored_slot slot, int32_t value) {
    return slot.function(slot.context, value);
}
stored_fn stored_get_function(void) { return stored_add_two; }
int32_t stored_slot_size(void) { return (int32_t)sizeof(stored_slot); }
int32_t stored_slot_function_offset(void) {
    return (int32_t)offsetof(stored_slot, function);
}
int32_t stored_slot_context_offset(void) {
    return (int32_t)offsetof(stored_slot, context);
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
extern "C" struct StoredSlot {
    function: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>
    context: RawPtr<u8>
}
extern "C" fn make_slot(
    function: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>,
    context: RawPtr<u8>
) -> StoredSlot as "stored_make_slot"
extern "C" fn call_slot(slot: StoredSlot, value: i32) -> i32 as "stored_call_slot"
extern "C" fn get_function() -> CFunctionPtr<fn(RawPtr<u8>, i32) -> i32> as "stored_get_function"
extern "C" var global_function: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32> as "stored_global_function"
extern "C" fn slot_size() -> i32 as "stored_slot_size"
extern "C" fn slot_function_offset() -> i32 as "stored_slot_function_offset"
extern "C" fn slot_context_offset() -> i32 as "stored_slot_context_offset"
fn main() {
    let callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create(0, fn(value: i32) -> i32 {
            return value + 1
        })
    unsafe {
        register(callback.function(), callback.context())
        io.println(fire(41))
        unregister()
        let slot: StoredSlot = make_slot(
            callback.function_pointer(), callback.context())
        io.println(call_slot(slot, 41))
        let returned: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32> =
            get_function()
        io.println(returned.call(RawPtr.null(), 40))
        io.println(global_function.call(RawPtr.null(), 40))
        io.println("layout {size_of(StoredSlot)} {offset_of(StoredSlot, function)} {offset_of(StoredSlot, context)}")
        io.println("c layout {slot_size()} {slot_function_offset()} {slot_context_offset()}")
    }
    let missing: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32> =
        CFunctionPtr.null()
    io.println(missing.is_null())
    let also_missing: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32> =
        CFunctionPtr.null()
    io.println(missing == also_missing)
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
[[ $(grep -c '^42$' "$tmp/native.out") -eq 4 ]]
grep -Fx 'true' "$tmp/native.out" >"$tmp/match"
sed -n 's/^layout //p' "$tmp/native.out" >"$tmp/beans.layout"
sed -n 's/^c layout //p' "$tmp/native.out" >"$tmp/c.layout"
diff -u "$tmp/c.layout" "$tmp/beans.layout"

# None of the negatives call into the fixture, so their package does not link
# it. Linking a library a program never uses still leaves a load-time
# dependency behind, and the loader has to find it again by name when the
# binary runs — which macOS does from the path recorded at link time and Linux
# does not do at all.
cat >"$tmp/negative.pot" <<'MOD'
module stored_callbacks
MOD
mkdir -p "$tmp/closed_twice" "$tmp/untyped_store" "$tmp/invalid_type" \
    "$tmp/null_call"
for negative in closed_twice untyped_store invalid_type null_call; do
    cp "$tmp/negative.pot" "$tmp/$negative/beans.pot"
done
cat >"$tmp/closed_twice/main.b" <<'BEANS'
package main

fn bad() {
    let callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create(0, fn(value: i32) -> i32 { return value })
    callback.close()
    callback.close()
}
BEANS
if "$beansc" check "$tmp/closed_twice/main.b" >"$tmp/closed_twice.out" 2>&1; then
    echo "a closed StoredCallback stayed usable" >&2
    exit 1
fi
grep -F 'use of moved value' "$tmp/closed_twice.out" >/dev/null

cat >"$tmp/untyped_store/main.b" <<'BEANS'
package main

extern "C" struct Slot {
    function: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>
    context: RawPtr<u8>
}

fn bad() {
    let callback: StoredCallback<fn(RawPtr<u8>, i32) -> i32> =
        StoredCallback.create(0, fn(value: i32) -> i32 { return value })
    let slot: Slot = Slot {
        function: callback.function(),
        context: callback.context(),
    }
}
BEANS
if "$beansc" check "$tmp/untyped_store/main.b" >"$tmp/untyped_store.out" 2>&1; then
    echo "an ordinary fn value was stored as a CFunctionPtr" >&2
    exit 1
fi
grep -F 'CFunctionPtr<fn(RawPtr<u8>, i32) -> i32>' \
    "$tmp/untyped_store.out" >/dev/null
grep -F 'fn(RawPtr<u8>, i32) -> i32' "$tmp/untyped_store.out" >/dev/null

cat >"$tmp/invalid_type/main.b" <<'BEANS'
package main

fn bad(pointer: CFunctionPtr<fn(string) -> i32>) {}
BEANS
if "$beansc" check "$tmp/invalid_type/main.b" \
    >"$tmp/invalid_type.out" 2>&1; then
    echo "CFunctionPtr accepted a non-C callback signature" >&2
    exit 1
fi
grep -F 'CFunctionPtr needs a C callback function type' \
    "$tmp/invalid_type.out" >/dev/null

cat >"$tmp/null_call/main.b" <<'BEANS'
package main

fn main() {
    let missing: CFunctionPtr<fn(RawPtr<u8>, i32) -> i32> =
        CFunctionPtr.null()
    unsafe {
        missing.call(RawPtr.null(), 0)
    }
}
BEANS
set +e
"$beansc" run "$tmp/null_call/main.b" >"$tmp/null.interp" 2>&1
null_interp_status=$?
set -e
[[ "$null_interp_status" -eq 3 ]]
grep -F 'cannot call a null CFunctionPtr' "$tmp/null.interp" >/dev/null
"$beansc" build "$tmp/null_call/main.b" -o "$tmp/null.native" \
    >"$tmp/null.build" 2>&1
set +e
"$tmp/null.native" >"$tmp/null.native.out" 2>&1
null_native_status=$?
set -e
[[ "$null_native_status" -eq 3 ]]
grep -F 'cannot call a null CFunctionPtr' "$tmp/null.native.out" >/dev/null

if [[ "${BEANS_SANITIZE_CALLBACKS:-0}" == "1" ]]; then
    # The null-call negative build above leaves its IR in build/main.ll.
    # Regenerate the positive callback program before compiling that IR with
    # sanitizers.
    "$beansc" build "$tmp/main.b" -o "$tmp/sanitize.native" \
        >"$tmp/sanitize.build" 2>&1
    clang -O1 -g -pthread -fsanitize=address,undefined \
        -fno-sanitize-recover=undefined -Wno-override-module \
        build/main.ll build/main_ffi.c build/beans_rt.c \
        "$tmp/stored_fixture.c" -lm -o "$tmp/stored_asan"
    # A leak is a sanitizer failure like any other: LeakSanitizer rides inside
    # ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
    # the status before reading the report, or this dies under `set -e` with the
    # report still unread in the capture file.
    if ! BEANS_NO_POOL=1 "$tmp/stored_asan" >"$tmp/asan.out" \
            2>"$tmp/asan.err"; then
        sed -n '1,160p' "$tmp/asan.err" >&2
        echo "stored_callbacks exited non-zero under the sanitizers" >&2
        exit 1
    fi
    if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:' \
        "$tmp/asan.err"; then
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
