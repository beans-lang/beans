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

echo "checking a contained call catches a panic raised across a C frame"
# issue #145: `contained f(args)` stops the unwind at a landing pad in the
# calling frame. When the panic is raised inside a Beans closure that a C
# function called, the walk has to cross that C frame to reach the pad — which
# works only because every frame on the path carries an unwind table. The
# failure must arrive as err(kind panic) with the callee's defers run and its
# locals dropped, identically on both backends; without the pad it is exit 3.
if [[ "$(uname -s)" == "Darwin" ]]; then
    DYLD_INSERT_LIBRARIES="$tmp/callbacks.dylib" \
        "$beansc" run test/cases/contained_ffi.b >"$tmp/ccffi.interp" 2>&1
else
    LD_PRELOAD="$tmp/callbacks.so" \
        "$beansc" run test/cases/contained_ffi.b >"$tmp/ccffi.interp" 2>&1
fi

"$beansc" build test/cases/contained_ffi.b -o "$tmp/ccffi.unlinked" \
    >"$tmp/ccffi.generate" 2>&1 || true
# The same flags the driver passes for a build that can unwind
# (src/driver.b): the pads are useless without a runtime that starts the
# unwind and unwind tables on every C frame between the panic and the pad.
clang -O2 -pthread -funwind-tables -fexceptions -DBEANS_FIBER_UNWIND=1 \
    -Wno-override-module build/contained_ffi.ll \
    build/beans_rt.c build/contained_ffi_ffi.c \
    test/fixtures/c_callback_helper.c -lm -o "$tmp/ccffi.native"
"$tmp/ccffi.native" >"$tmp/ccffi.native.out" 2>&1
diff -u test/cases/contained_ffi.out "$tmp/ccffi.interp"
diff -u test/cases/contained_ffi.out "$tmp/ccffi.native.out"

echo "ok closures, function references, void calls, floats, C records, contained across C"
