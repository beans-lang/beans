#!/usr/bin/env bash
# A module built with `--emit shared` has no main. The static prologue used to
# be emitted inside main, so it never ran: every `pub static` read as the zero
# it was born with, silently, and once static reads were guarded it panicked
# instead — which is how it was found. The prologue is a function of its own
# now, called from main when there is one and from the first static read when
# there is not.
#
# The host here is C rather than JavaScript because the fault is about the
# module having no entry point, not about the target. A wasm module loaded
# from JS has the same shape and the same fix.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/lib.b" <<'BEANS'
package main

fn seeded(value: int) -> int {
    Built.count += 1
    return value * 2
}

class Built {
    pub static count: int = 0
}

class Table {
    pub static seed: int = 42
    pub static derived: int = seeded(21)
    pub static label: string = "ready"
}

pub extern "C" fn read_seed() -> i64 as "shared_read_seed" {
    return Table.seed
}

pub extern "C" fn read_derived() -> i64 as "shared_read_derived" {
    return Table.derived
}

pub extern "C" fn read_built() -> i64 as "shared_read_built" {
    return Built.count
}

pub extern "C" fn label_len() -> i64 as "shared_label_len" {
    return Table.label.len()
}
BEANS

case "$(uname -s)" in
    Darwin) suffix=dylib ;;
    *)      suffix=so ;;
esac

"$beansc" build --emit shared "$tmp/lib.b" -o "$tmp/libshared.$suffix" >/dev/null

cat >"$tmp/host.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
    void* handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    long long (*seed)(void)    = (long long (*)(void))dlsym(handle, "shared_read_seed");
    long long (*derived)(void) = (long long (*)(void))dlsym(handle, "shared_read_derived");
    long long (*built)(void)   = (long long (*)(void))dlsym(handle, "shared_read_built");
    long long (*label)(void)   = (long long (*)(void))dlsym(handle, "shared_label_len");
    if (!seed || !derived || !built || !label) { printf("dlsym failed\n"); return 1; }
    /* the first call is what has to run the prologue; the rest must not
       run it again, which is what the build count proves */
    printf("seed %lld\n", seed());
    printf("derived %lld\n", derived());
    printf("label %lld\n", label());
    printf("built %lld\n", built());
    printf("again %lld %lld\n", seed(), built());
    return 0;
}
C

cc -o "$tmp/host" "$tmp/host.c"
"$tmp/host" "$tmp/libshared.$suffix" >"$tmp/got"

cat >"$tmp/want" <<'EOF'
seed 42
derived 42
label 5
built 1
again 42 1
EOF

if ! diff -u "$tmp/want" "$tmp/got"; then
    echo "a shared module's statics did not initialise correctly" >&2
    exit 1
fi

echo "ok shared statics: a module with no main initialises on first read, once"
