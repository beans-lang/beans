#!/usr/bin/env bash
# The crema-port findings as one suite: string escapes render identically in
# both compilers and \{ never opens a slot (finding 1), '{{' gets a diagnostic
# naming the real escape (finding 2), plain structs carry field defaults the
# way classes do (finding 3), both compilers run main() on the real process
# main thread (finding 7), and a missing C runtime names the absolute path it
# looked for rather than a relative one.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-crema-findings.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_both() {
    local name=$1
    ./build/beansc run "test/cases/$name.b" >"$tmp/$name.interp"
    ./build/beansc build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

check_bad() {
    local file=$1
    local message=$2
    if ./build/beansc check "test/cases/$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    grep -Fq "$message" "$tmp/bad"
}

run_both string_escapes_ok
run_both struct_defaults_ok

check_bad string_escapes_bad.b "'{{' is not an escape — it starts an interpolation whose expression begins with '{'; for a literal brace write \\{ or \\}"
check_bad string_escapes_bad.b "empty {} in string"
check_bad struct_defaults_bad.b "initializer for Mixed is missing field 'required'"

# main() runs on the real process main thread under both compilers — the
# guarantee AppKit and dispatch-main-queue programs stand on. Probed through
# a C fixture on the hosts that can answer the question.
os=$(uname -s)
if [[ "$os" == "Darwin" || "$os" == "Linux" ]]; then
    mkdir -p "$tmp/mainthread"
    cat >"$tmp/mainthread/fixture.c" <<'C'
#if defined(__APPLE__)
#include <pthread.h>
int fixture_on_main_thread(void) { return pthread_main_np() == 1; }
#else
#include <unistd.h>
#include <sys/syscall.h>
int fixture_on_main_thread(void) {
    return (long)syscall(SYS_gettid) == (long)getpid();
}
#endif
C
    if [[ "$os" == "Darwin" ]]; then
        clang -dynamiclib "$tmp/mainthread/fixture.c" \
            -o "$tmp/mainthread/libmain_fixture.dylib"
        export DYLD_LIBRARY_PATH="$tmp/mainthread${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    else
        clang -shared -fPIC "$tmp/mainthread/fixture.c" \
            -o "$tmp/mainthread/libmain_fixture.so"
        export LD_LIBRARY_PATH="$tmp/mainthread${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    cat >"$tmp/mainthread/beans.pot" <<'MOD'
module crema_mainthread
link all search "."
link all library "main_fixture"
MOD
    cat >"$tmp/mainthread/main.b" <<'BEANS'
package main

import std.io

extern "C" fn on_main_thread() -> i32 as "fixture_on_main_thread"

fn main() {
    unsafe {
        io.println("main thread: {on_main_thread()}")
    }
}
BEANS
    cd "$tmp/mainthread"
    "$OLDPWD/build/beansc" run main.b >"$tmp/mainthread/interp.out"
    grep -Fqx "main thread: 1" "$tmp/mainthread/interp.out"
    BEANS_RUNTIME="$OLDPWD/runtime/beans_rt.c" \
        "$OLDPWD/build/beansc" build main.b -o probe >/dev/null
    ./probe >"$tmp/mainthread/native.out"
    grep -Fqx "main thread: 1" "$tmp/mainthread/native.out"
    cd "$OLDPWD"
    echo "ok main-thread guarantee"
fi

# A compiler built in the tree resolves both C sources from the working
# directory, so every package built from anywhere else fails to find them. That
# is by design — pairing a tree compiler with another package's runtime is a
# version skew with no handshake to catch it — but the old message named a
# relative path, which reads as "the runtime is missing" rather than "you are
# in the wrong directory". The message has to name the path it actually tried.
root=$PWD
mkdir -p "$tmp/elsewhere"
cat >"$tmp/elsewhere/main.b" <<'BEANS'
import std.io

fn main() {
    io.println("hi")
}
BEANS
cd "$tmp/elsewhere"
# The compiler prints the path getcwd() reports, which on macOS resolves the
# /var -> /private/var symlink that $PWD keeps. Comparing against the logical
# path would pass on a substring instead of on the answer.
here=$(pwd -P)
if env -u BEANS_RUNTIME -u BEANS_WASM_HOST \
    BEANS_STDLIB="$root/stdlib/std" \
    "$root/build/beansc" build main.b -o probe >"$tmp/runtime_missing" 2>&1; then
    echo "a build with no runtime unexpectedly passed" >&2
    exit 1
fi
grep -Fq "$here/runtime/beans_rt.c:0:0: error:" "$tmp/runtime_missing"
grep -Fq "relative to the working directory, not to beansc" \
    "$tmp/runtime_missing"
# A variable that is set but wrong is a different mistake and says so.
if env BEANS_RUNTIME="$tmp/nowhere/beans_rt.c" \
    BEANS_STDLIB="$root/stdlib/std" \
    "$root/build/beansc" build main.b -o probe >"$tmp/runtime_wrong" 2>&1; then
    echo "a build with a bad BEANS_RUNTIME unexpectedly passed" >&2
    exit 1
fi
grep -Fq "BEANS_RUNTIME is set to '$tmp/nowhere/beans_rt.c'" \
    "$tmp/runtime_wrong"
if grep -Fq "relative to the working directory" "$tmp/runtime_wrong"; then
    echo "a configured BEANS_RUNTIME was blamed on the working directory" >&2
    exit 1
fi
# doctor reports the same path, absolute, for the same reason.
env -u BEANS_RUNTIME -u BEANS_WASM_HOST BEANS_STDLIB="$root/stdlib/std" \
    "$root/build/beansc" doctor >"$tmp/doctor.out" 2>&1 || true
grep -Fq "$here/runtime/beans_rt.c (missing)" "$tmp/doctor.out"
cd "$root"
echo "ok runtime-path diagnostics"

echo "ok crema findings: escapes, brace diagnostics, struct defaults, main thread, runtime paths"
