#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-c-wide-args.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking C calls past every argument register bank"
if [[ "$(uname -s)" == "Darwin" ]]; then
    clang -O2 -dynamiclib test/fixtures/c_wide_args_helper.c -o "$tmp/wide.dylib"
    DYLD_INSERT_LIBRARIES="$tmp/wide.dylib" \
        "$beansc" run test/cases/c_wide_args.b >"$tmp/interp"
else
    clang -O2 -shared -fPIC test/fixtures/c_wide_args_helper.c -o "$tmp/wide.so"
    LD_PRELOAD="$tmp/wide.so" \
        "$beansc" run test/cases/c_wide_args.b >"$tmp/interp"
fi

# The normal link reports the intentionally external test symbols, so link the
# fixture into the acceptance binary explicitly, as c_layout_c_abi.sh does.
"$beansc" build test/cases/c_wide_args.b -o "$tmp/unlinked" \
    >"$tmp/generate" 2>&1 || true
test -f build/c_wide_args.ll
grep -q 'beans_test_wide_ints' build/c_wide_args.ll
clang -O2 -pthread -Wno-override-module build/c_wide_args.ll \
    build/beans_rt.c build/c_wide_args_ffi.c \
    test/fixtures/c_wide_args_helper.c -lm -o "$tmp/native"
"$tmp/native" >"$tmp/native.out"

clang -O1 -g -pthread -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -Wno-override-module \
    build/c_wide_args.ll build/beans_rt.c build/c_wide_args_ffi.c \
    test/fixtures/c_wide_args_helper.c -lm -o "$tmp/asan"
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|runtime error:' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi

diff -u test/cases/c_wide_args.out "$tmp/interp"
diff -u test/cases/c_wide_args.out "$tmp/native.out"
diff -u test/cases/c_wide_args.out "$tmp/asan.out"

echo "ok stack-passed integers, floats, narrow ints, records, and callbacks"
