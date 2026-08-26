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

class Device {
    pub static attached: int = 0
    pub static hits: int = 0
    pub static name: string = "none"
}

pub extern "C" fn device_attach(id: i64) -> i64 as "shared_device_attach" {
    Device.attached = id as int
    Device.hits += 1
    Device.name = "gpu"
    return 0
}

pub extern "C" fn device_attached() -> i64 as "shared_device_attached" {
    return Device.attached as i64
}

pub extern "C" fn device_hits() -> i64 as "shared_device_hits" {
    return Device.hits
}

pub extern "C" fn device_name_len() -> i64 as "shared_device_name_len" {
    return Device.name.len()
}

class Marker {
    pub label: string

    pub fn init(label: string) {
        self.label = label
    }
    fn deinit() {
        Freed.count += 1
    }
}

class Freed {
    pub static count: int = 0
}

class Slot {
    pub static held: Marker = new Marker("default")
}

pub extern "C" fn slot_replace() -> i64 as "shared_slot_replace" {
    Slot.held = new Marker("live")
    return 0
}

pub extern "C" fn slot_label_len() -> i64 as "shared_slot_label_len" {
    return Slot.held.label.len()
}

pub extern "C" fn slot_freed() -> i64 as "shared_slot_freed" {
    return Freed.count
}

class Pair {
    pub static first: int = 0
    pub static second: int = 0
}

pub extern "C" fn pair_first() -> i64 as "shared_pair_first" {
    Pair.first = 11
    return 0
}

pub extern "C" fn pair_second() -> i64 as "shared_pair_second" {
    Pair.second = 22
    return 0
}

pub extern "C" fn pair_read() -> i64 as "shared_pair_read" {
    return Pair.first * 100 + Pair.second
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

# Everything above reads. That is the shape that hid the next fault: the
# prologue runs on first touch, so a host whose first call WRITES stored into
# statics the prologue had not reached, and the next read ran the prologue on
# top of the writes. The export answered ok and the device was not attached.
# Nothing above could see it, because a read always went first.
#
# So the interesting call has to be the very first thing the process does — no
# arrange step, no warm-up, nothing. One process per lane per order is the
# point: if a bug depends on being first, nothing that runs second can see it.
# Which also means one cold lane cannot cover two first calls. The attach lane
# and the slot lane each get their own run.
# Each lane below was checked against a build of the pre-fix compiler, one
# lane at a time, and each fails there for its own reason. That is not
# ceremony: an export can arrange the prologue *inside itself* and nothing at
# the call site shows it. A first call that reads a static before it writes
# one arms the prologue in the callee; a first call that writes only the
# declared default overwrites itself with the same bytes the prologue would.
# Either one passes cold on a broken compiler and looks like a real cold
# lane. Reading the harness cannot tell you which you have — only running it
# against the bug can.
#
# So a lane added without a pre-fix compiler to test it against is a lane
# nobody can validate. This file honours $BEANSC for exactly that: build a
# compiler from before the fix and run
#
#     BEANSC=/path/to/pre-fix/beansc bash test/shared_statics.sh
#
# one lane at a time — the first failure exits, so a combined run never tells
# you whether the later lanes could fail at all.
cat >"$tmp/order.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
    void* handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    long long (*attach)(long long) =
        (long long (*)(long long))dlsym(handle, "shared_device_attach");
    long long (*attached)(void) = (long long (*)(void))dlsym(handle, "shared_device_attached");
    long long (*hits)(void)     = (long long (*)(void))dlsym(handle, "shared_device_hits");
    long long (*name)(void)     = (long long (*)(void))dlsym(handle, "shared_device_name_len");
    long long (*replace)(void)  = (long long (*)(void))dlsym(handle, "shared_slot_replace");
    long long (*label)(void)    = (long long (*)(void))dlsym(handle, "shared_slot_label_len");
    long long (*freed)(void)    = (long long (*)(void))dlsym(handle, "shared_slot_freed");
    if (!attach || !attached || !hits || !name) { printf("dlsym failed\n"); return 1; }
    if (!replace || !label || !freed) { printf("dlsym failed\n"); return 1; }
    long long (*p1)(void)    = (long long (*)(void))dlsym(handle, "shared_pair_first");
    long long (*p2)(void)    = (long long (*)(void))dlsym(handle, "shared_pair_second");
    long long (*pread)(void) = (long long (*)(void))dlsym(handle, "shared_pair_read");
    if (!p1 || !p2 || !pread) { printf("dlsym failed\n"); return 1; }
    int warm = strcmp(argv[3], "warm") == 0;
    if (strcmp(argv[2], "attach") == 0) {
        /* the warm order arranges first; the cold order does not arrange */
        if (warm) { attached(); }
        printf("attach %lld\n", attach(9));
        printf("attached %lld\n", attached());
        printf("hits %lld\n", hits());
        printf("name %lld\n", name());
    } else if (strcmp(argv[2], "pair") == 0) {
        /* Two writing exports back to back, neither of which reads. The
           fault is not "the first call is sacrificed" — it is "every call
           before the first read is sacrificed", and only a second writing
           call can tell those two apart. A fix that armed the prologue once
           per call would pass the attach lane and fail here. */
        if (warm) { pread(); }
        printf("first %lld\n", p1());
        printf("second %lld\n", p2());
        printf("pair %lld\n", pread());
    } else {
        /* Replacing an owned static releases what it held. The visible half
           of this bug was the lost write; the expensive half was that the
           release loaded the null a zeroed global holds, so the default it
           dropped was never freed. A deinit that never runs prints nothing
           and passes every gate that only reads answers, so count the frees
           — and the replace has to be the first call for the count to mean
           anything, which is why this is its own lane. */
        if (warm) { label(); }
        printf("replace %lld\n", replace());
        printf("label %lld\n", label());
        printf("freed %lld\n", freed());
    }
    return 0;
}
C

cc -o "$tmp/order" "$tmp/order.c"

check_lane() {
    lane=$1
    "$tmp/order" "$tmp/libshared.$suffix" "$lane" cold >"$tmp/$lane.cold"
    "$tmp/order" "$tmp/libshared.$suffix" "$lane" warm >"$tmp/$lane.warm"
    # The values, so that two runs agreeing on a wrong answer cannot pass...
    if ! diff -u "$tmp/$lane.want" "$tmp/$lane.cold"; then
        echo "the $lane lane lost its first call to the static prologue" >&2
        exit 1
    fi
    # ...and the two orders against each other, which is the property itself:
    # when the first call happens cannot change what the module holds.
    if ! diff -u "$tmp/$lane.warm" "$tmp/$lane.cold"; then
        echo "the $lane lane answered differently depending on which export ran first" >&2
        exit 1
    fi
}

cat >"$tmp/attach.want" <<'EOF'
attach 0
attached 9
hits 1
name 3
EOF
check_lane attach

cat >"$tmp/slot.want" <<'EOF'
replace 0
label 4
freed 1
EOF
check_lane slot

cat >"$tmp/pair.want" <<'EOF'
first 0
second 0
pair 1122
EOF
check_lane pair

echo "ok shared statics: a module with no main initialises on first read, once"
echo "ok shared statics: a writing export keeps its writes when it is the first call"
echo "ok shared statics: replacing an owned static frees what it held, in either order"
echo "ok shared statics: two writing calls before any read both keep their writes"
