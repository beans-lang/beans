#!/usr/bin/env bash
# Calls into C `...` tails, checked against a Clang-compiled reference.
#
# The reason this suite exists rather than a spot check: a variadic tail is
# classified by different rules from the fixed head on a supported target.
# Apple's arm64 ABI passes the whole tail on the stack at each argument's
# natural size while the head stays in registers, so a caller that declares a
# variadic callee with a fixed signature — the obvious workaround before this
# landed — passes the values in the wrong place and gets silence, not an
# error. test/fixtures/c_variadic_helper.c reads every tail through va_arg, so
# it is the target's own rules that decide whether these numbers come out.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-c-variadic.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking C variadic calls in both backends"
if [[ "$(uname -s)" == "Darwin" ]]; then
    clang -O2 -dynamiclib test/fixtures/c_variadic_helper.c -o "$tmp/va.dylib"
    DYLD_INSERT_LIBRARIES="$tmp/va.dylib" \
        "$beansc" run test/cases/c_variadic.b >"$tmp/interp"
else
    clang -O2 -shared -fPIC test/fixtures/c_variadic_helper.c -o "$tmp/va.so"
    LD_PRELOAD="$tmp/va.so" \
        "$beansc" run test/cases/c_variadic.b >"$tmp/interp"
fi

# The normal link reports the intentionally external test symbols, so link the
# fixture into the acceptance binary explicitly, as c_wide_args.sh does.
"$beansc" build test/cases/c_variadic.b -o "$tmp/unlinked" \
    >"$tmp/generate" 2>&1 || true
test -f build/c_variadic.ll
test -f build/c_variadic_ffi.c

# The claim, on the emitted code rather than on the answer: the callee is
# declared variadic in both the wrapper's C prototype and the module, and one
# declaration owns one wrapper per call-site shape rather than one wrapper.
grep -q 'extern int64_t beans_test_va_narrow(int64_t arg0, \.\.\.);' \
    build/c_variadic_ffi.c || {
    echo "the generated wrapper does not declare the callee variadic" >&2
    sed -n '1,40p' build/c_variadic_ffi.c >&2
    exit 1
}
grep -q 'declare i64 @beans_test_va_narrow(i64, \.\.\.)' build/c_variadic.ll || {
    echo "the module declares a variadic import with a fixed signature" >&2
    grep -n 'beans_test_va_narrow' build/c_variadic.ll >&2
    exit 1
}
shapes=$(grep -c 'beans_test_va_narrow(\*(int64_t\*)args\[0\]' \
    build/c_variadic_ffi.c)
if [ "$shapes" -ne 3 ]; then
    echo "expected one wrapper per call-site tail for beans_test_va_narrow, got $shapes" >&2
    exit 1
fi

clang -O2 -pthread -Wno-override-module build/c_variadic.ll \
    build/beans_rt.c build/c_variadic_ffi.c \
    test/fixtures/c_variadic_helper.c -lm -o "$tmp/native"
"$tmp/native" >"$tmp/native.out"

clang -O1 -g -pthread -fsanitize=address,undefined \
    -fno-sanitize-recover=undefined -Wno-override-module \
    build/c_variadic.ll build/beans_rt.c build/c_variadic_ffi.c \
    test/fixtures/c_variadic_helper.c -lm -o "$tmp/asan"
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

diff -u test/cases/c_variadic.out "$tmp/interp"
diff -u test/cases/c_variadic.out "$tmp/native.out"
diff -u test/cases/c_variadic.out "$tmp/asan.out"

echo "checking what '...' refuses"
refuse() { # <label> <required message fragment> <source lines...>
    local label=$1 fragment=$2
    shift 2
    printf '%s\n' "$@" >"$tmp/$label.b"
    if "$beansc" check "$tmp/$label.b" >"$tmp/$label.err" 2>&1; then
        echo "c_variadic: $label was accepted" >&2
        cat "$tmp/$label.err" >&2
        exit 1
    fi
    grep -qF "$fragment" "$tmp/$label.err" || {
        echo "c_variadic: $label was refused with the wrong message:" >&2
        cat "$tmp/$label.err" >&2
        exit 1
    }
}

# A `...` describes how a host C function reads arguments. A Beans body would
# have to implement one, and there is no va_list to implement it with.
refuse beans_body "'...' is only for an extern \"C\" declaration" \
    'fn add(a: i32, ...) -> i32 { return a }' \
    'fn main() {}'
refuse export_body 'cannot be variadic' \
    'pub extern "C" fn add(a: i32, ...) -> i32 { return a }' \
    'fn main() {}'
# C gives `...` no meaning without a named parameter in front of it.
refuse no_fixed "'...' needs at least one fixed parameter before it" \
    'extern "C" fn f(...) -> i32' \
    'fn main() {}'
refuse not_last "'...' must be the last parameter" \
    'extern "C" fn f(a: i32, ..., b: i32) -> i32' \
    'fn main() {}'
# The fixed head is still a signature.
refuse too_few 'takes at least 1 argument but got 0' \
    'extern "C" fn f(a: i32, ...) -> i32' \
    'fn main() { unsafe { let x: i32 = f() } }'
# Past `...` the prototype says nothing, so a value with no single C spelling
# has nothing to be passed as.
refuse tail_string "variadic argument 2 needs an integer" \
    'extern "C" fn f(a: i32, ...) -> i32' \
    'fn main() { unsafe { let x: i32 = f(1, "hi") } }'
refuse tail_record "variadic argument 2 needs an integer" \
    'extern "C" struct Pair { a: u32 }' \
    'extern "C" fn f(a: i32, ...) -> i32' \
    'fn main() { unsafe { let p: Pair = Pair { a: 1 }' \
    '  let x: i32 = f(1, p) } }'
refuse tail_list "variadic argument 2 needs an integer" \
    'extern "C" fn f(a: i32, ...) -> i32' \
    'fn main() { unsafe { let items: List<int> = [1]' \
    '  let x: i32 = f(1, items) } }'
# A variadic call is still a C call.
refuse needs_unsafe "extern C call 'f'" \
    'extern "C" fn f(a: i32, ...) -> i32' \
    'fn main() { let x: i32 = f(1, 2 as i32) }'

echo "ok C variadic calls: promotions, stack tails, per-call-site classification"
