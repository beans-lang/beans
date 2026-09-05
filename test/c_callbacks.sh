#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-c-callbacks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking borrowed synchronous C callbacks"
if [[ "$(uname -s)" == "Darwin" ]]; then
    clang -O2 -dynamiclib test/fixtures/c_callback_helper.c -o "$tmp/callbacks.dylib"
    DYLD_INSERT_LIBRARIES="$tmp/callbacks.dylib" \
        "$beansc" run test/cases/c_callbacks.b >"$tmp/interp"
else
    clang -O2 -shared -fPIC test/fixtures/c_callback_helper.c -o "$tmp/callbacks.so"
    LD_PRELOAD="$tmp/callbacks.so" \
        "$beansc" run test/cases/c_callbacks.b >"$tmp/interp"
fi

"$beansc" build test/cases/c_callbacks.b -o "$tmp/unlinked" \
    >"$tmp/generate" 2>&1 || true
test -f build/c_callbacks.ll
test -f build/c_callbacks_ffi.c
grep -q 'beans_cb_dispatch_' build/c_callbacks.ll
grep -q '_Thread_local void.*_env' build/c_callbacks_ffi.c
grep -q 'beans_test_map_point' build/c_callbacks_ffi.c
grep -q '^typedef struct Point {' build/c_callbacks_ffi.c
grep -q '^  int32_t x;$' build/c_callbacks_ffi.c
grep -q '^  int32_t y;$' build/c_callbacks_ffi.c

clang -O2 -pthread -Wno-override-module build/c_callbacks.ll \
    build/beans_rt.c build/c_callbacks_ffi.c \
    test/fixtures/c_callback_helper.c -lm -o "$tmp/native"
"$tmp/native" >"$tmp/native.out"

clang -O1 -g -pthread -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -Wno-override-module \
    build/c_callbacks.ll build/beans_rt.c build/c_callbacks_ffi.c \
    test/fixtures/c_callback_helper.c -lm -o "$tmp/asan"
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
# The guarded run above already fails on a leak (LeakSanitizer rides inside
# ASan on Linux and exits non-zero); the grep names all three so a report that
# does not change the exit status is caught too.
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|runtime error:' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi

diff -u test/cases/c_callbacks.out "$tmp/interp"
diff -u test/cases/c_callbacks.out "$tmp/native.out"
diff -u test/cases/c_callbacks.out "$tmp/asan.out"

echo "checking callback panic handoff"
set +e
if [[ "$(uname -s)" == "Darwin" ]]; then
    DYLD_INSERT_LIBRARIES="$tmp/callbacks.dylib" \
        "$beansc" run test/cases/c_callback_panic.b \
        >"$tmp/panic.interp" 2>&1
else
    LD_PRELOAD="$tmp/callbacks.so" \
        "$beansc" run test/cases/c_callback_panic.b \
        >"$tmp/panic.interp" 2>&1
fi
interp_status=$?
set -e
test "$interp_status" -eq 3

"$beansc" build test/cases/c_callback_panic.b -o "$tmp/panic.unlinked" \
    >"$tmp/panic.generate" 2>&1 || true
clang -O2 -pthread -Wno-override-module build/c_callback_panic.ll \
    build/beans_rt.c build/c_callback_panic_ffi.c \
    test/fixtures/c_callback_helper.c -lm -o "$tmp/panic.native"
set +e
"$tmp/panic.native" >"$tmp/panic.native.out" 2>&1
native_status=$?
set -e
test "$native_status" -eq 3
diff -u test/cases/c_callback_panic.out "$tmp/panic.interp"
diff -u test/cases/c_callback_panic.out "$tmp/panic.native.out"

echo "ok closures, function references, void calls, floats, and C records"
