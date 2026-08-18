#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-dylib.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [[ "$(uname -s)" == Darwin ]]; then ext=dylib; else ext=so; fi

echo "checking the failure paths with no library at all"
# The example runs without a library, so `make test` covers every error path on its own.
./build/beansc run examples/dynamic_library.b >"$tmp/skip.interp"
./build/beansc build examples/dynamic_library.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/skip.native"
diff -u "$tmp/skip.interp" "$tmp/skip.native"
diff -u - "$tmp/skip.interp" <<'EXPECTED'
a missing library: not_found
an empty path: invalid
not a library: not_found
no library given, so only the failure paths ran
done
EXPECTED

echo "building a library to load"
# Deliberately small, and every function takes and returns machine words — which is the
# whole calling contract. `plug_zero` exists because a symbol at a zero *return* value
# must not be confused with a symbol that failed to resolve.
cat >"$tmp/plug.c" <<'PLUG'
long long plug_answer(void) { return 42; }
long long plug_double(long long x) { return x * 2; }
long long plug_add(long long a, long long b) { return a + b; }
long long plug_mix(long long a, long long b, long long c) {
    return a * 100 + b * 10 + c;
}
long long plug_zero(void) { return 0; }
PLUG
clang -shared -fPIC -O1 "$tmp/plug.c" -o "$tmp/libplug.$ext" 2>"$tmp/cc.log" || {
    echo "could not build the test library" >&2
    cat "$tmp/cc.log" >&2
    exit 1
}

echo "checking loading, resolving and calling in both backends"
BEANS_DYLIB_EXAMPLE="$tmp/libplug.$ext" ./build/beansc run examples/dynamic_library.b \
    >"$tmp/load.interp"
BEANS_DYLIB_EXAMPLE="$tmp/libplug.$ext" "$tmp/native" >"$tmp/load.native"
diff -u "$tmp/load.interp" "$tmp/load.native"
diff -u - "$tmp/load.interp" <<'EXPECTED'
a missing library: not_found
an empty path: invalid
not a library: not_found
opened the library
has plug_add true, has a made-up name false
resolved four symbols true
no arguments gives 42
one argument gives 42
two arguments give 42
three arguments give 123
a function returning zero returns 0
a missing symbol: not_found
closed cleanly true
finding after close: closed
library ok
done
EXPECTED

echo "checking the answers come from the library, not from anywhere else"
# 42 four different ways would also be produced by a stub that always returns 42, so the
# arguments are varied and each result is a distinct number that only that function
# computes.
cat >"$tmp/values.b" <<VALUES
import std.io
import std.dl
import std.dylib
fn go() -> Result<int> {
    let lib: dylib.Dylib = dylib.Dylib.open("$tmp/libplug.$ext")?
    let double: dylib.Symbol = lib.find("plug_double")?
    let add: dylib.Symbol = lib.find("plug_add")?
    let mix: dylib.Symbol = lib.find("plug_mix")?
    unsafe {
        io.println("double 7 {dl.call1(double.address, 7)}")
        io.println("double -3 {dl.call1(double.address, 0 - 3)}")
        io.println("add 100 23 {dl.call2(add.address, 100, 23)}")
        io.println("add negatives {dl.call2(add.address, 0 - 5, 0 - 6)}")
        io.println("mix 9 8 7 {dl.call3(mix.address, 9, 8, 7)}")
        // Argument order matters and is easy to get backwards, so it is checked.
        io.println("mix 7 8 9 {dl.call3(mix.address, 7, 8, 9)}")
        // A large value proves the arguments really are 64-bit words rather than
        // truncated to int on the way through.
        io.println("double a big number {dl.call1(double.address, 4000000000)}")
    }
    return ok(1)
}
fn main() {
    match go() { ok(n) => io.println("values ok"), err(e) => io.println("failed {e.msg}") }
}
VALUES
./build/beansc run "$tmp/values.b" >"$tmp/values.interp"
./build/beansc build "$tmp/values.b" -o "$tmp/values" >/dev/null 2>&1
"$tmp/values" >"$tmp/values.native"
diff -u "$tmp/values.interp" "$tmp/values.native"
diff -u - "$tmp/values.interp" <<'EXPECTED'
double 7 14
double -3 -6
add 100 23 123
add negatives -11
mix 9 8 7 987
mix 7 8 9 789
double a big number 8000000000
values ok
EXPECTED

echo "checking calling a raw address is refused outside unsafe"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
# The reason this matters: the signature is the caller's guess, and a wrong guess
# corrupts the stack instead of raising anything. All four arities are gated, because
# gating three of four is the same as gating none.
for arity in 0 1 2 3; do
    expect_error "dl.call$arity requires unsafe { }" "test/cases/dl_call${arity}_safe.b"
done
# Resolving is *not* gated — holding an address is harmless, and requiring unsafe for it
# would train callers to wrap the safe part too.
./build/beansc check test/cases/dl_resolve_safe.b >/dev/null
# Move-only, so a library cannot be closed twice.
expect_error "is move-only" test/cases/dylib_no_copy.b
expect_error "init of 'dylib.Dylib' isn't pub" test/cases/dylib_private_init.b

echo "checking there is no wrapper that launders the unsafety"
# A dylib.call2(...) helper in the package would need its own unsafe block, and then the
# caller would not need one. The whole guarantee rests on there being no such function.
if grep -nE '^\s*pub fn call' stdlib/std/dylib/dylib.b; then
    echo "std.dylib grew a calling wrapper, which hides the unsafe requirement" >&2
    exit 1
fi
if grep -n 'unsafe' stdlib/std/dylib/dylib.b | grep -v '^\s*[0-9]*://' | grep -vE '^\s*[0-9]*:\s*(//|///)'; then
    echo "std.dylib opened an unsafe block; calling must stay at the call site" >&2
    exit 1
fi

echo "checking symbols do not leak into the global namespace"
# RTLD_LOCAL is not a detail. RTLD_GLOBAL would publish the library's symbols where an
# extern "C" fn resolves them — through dlsym in the interpreter, through the linker in a
# native build — so the same program would link in one backend and not the other.
grep -q 'RTLD_NOW | RTLD_LOCAL' runtime/beans_rt.c
# Comment lines are skipped, because both files explain at length why RTLD_GLOBAL is
# wrong — a grep that matched the explanation would fail on the documentation.
if grep -nE 'RTLD_GLOBAL' runtime/beans_rt.c \
        | grep -vE ':[[:space:]]*(//|\*)'; then
    echo "RTLD_GLOBAL would make extern \"C\" resolution differ between backends" >&2
    exit 1
fi
# And the observable consequence: an extern declaration of a symbol that only exists in
# the loaded library must not resolve, in either backend.
cat >"$tmp/leak.b" <<LEAK
import std.io
import std.dylib
extern "C" fn plug_add(a: i64, b: i64) -> i64
fn main() {
    match dylib.Dylib.open("$tmp/libplug.$ext") {
        ok(lib) => {
            unsafe {
                // plug_add is in the library, but opened RTLD_LOCAL, so this must not
                // find it. A crash or a 3 here would mean the symbol leaked.
                io.println("extern call gave {plug_add(1, 2)}")
            }
        }
        err(e) => io.println("could not open: {e.msg}"),
    }
}
LEAK
# The interpreter resolves extern names at call time, so it must fail to find it. Native
# resolves at link time, so the link itself must fail. Either way: not reachable.
if ./build/beansc run "$tmp/leak.b" >"$tmp/leak.out" 2>&1; then
    if grep -q 'extern call gave 3' "$tmp/leak.out"; then
        echo "a symbol from an RTLD_LOCAL library was reachable through extern \"C\"" >&2
        cat "$tmp/leak.out" >&2
        exit 1
    fi
fi
if ./build/beansc build "$tmp/leak.b" -o "$tmp/leak" >"$tmp/leak.build" 2>&1; then
    if "$tmp/leak" >"$tmp/leak.native.out" 2>&1; then
        if grep -q 'extern call gave 3' "$tmp/leak.native.out"; then
            echo "the native build reached an RTLD_LOCAL symbol through extern \"C\"" >&2
            exit 1
        fi
    fi
fi

echo "checking a library closes exactly once, even when nobody says so"
cat >"$tmp/drop.b" <<DROP
import std.io
import std.dylib
fn once() -> Result<bool> {
    // Never closed on purpose; deinit must dlclose it.
    let lib: dylib.Dylib = dylib.Dylib.open("$tmp/libplug.$ext")?
    return ok(lib.has("plug_add"))
}
fn main() {
    var made: int = 0
    var i: int = 0
    for i < 200 {
        match once() {
            ok(fine) => { if fine { made += 1 } }
            err(e) => io.println("failed at {i}: {e.msg}"),
        }
        i += 1
    }
    io.println("opened and dropped {made} libraries")
}
DROP
./build/beansc run "$tmp/drop.b" >"$tmp/drop.interp"
./build/beansc build "$tmp/drop.b" -o "$tmp/drop" >/dev/null 2>&1
"$tmp/drop" >"$tmp/drop.native"
diff -u "$tmp/drop.interp" "$tmp/drop.native"
grep -q '^opened and dropped 200 libraries$' "$tmp/drop.interp"

echo "checking no memory errors under ASan"
# dlopen/dlclose plus calls through resolved addresses is exactly where a lifetime bug
# would live, and the pool would hide it from `leaks`.
BEANS_DYLIB_EXAMPLE="$tmp/libplug.$ext" ./build/beansc build examples/dynamic_library.b \
    --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/dynamic_library.ll build/beans_rt.c -lm -o "$tmp/asan" 2>"$tmp/asan.build"
BEANS_DYLIB_EXAMPLE="$tmp/libplug.$ext" BEANS_NO_POOL=1 "$tmp/asan" \
    >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/load.interp" "$tmp/asan.out"

echo "ok dynamic libraries: RTLD_LOCAL, resolution, unsafe calls, and clean closing"
