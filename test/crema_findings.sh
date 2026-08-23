#!/usr/bin/env bash
# The crema-port findings as one suite: string escapes render identically in
# both compilers and \{ never opens a slot (finding 1), '{{' gets a diagnostic
# naming the real escape (finding 2), plain structs carry field defaults the
# way classes do (finding 3), and both compilers run main() on the real
# process main thread (finding 7).
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

echo "ok crema findings: escapes, brace diagnostics, struct defaults, main thread"
