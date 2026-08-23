#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-abi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the runtime derives the same numbers"
# The runtime computes them from sizeof(void*) rather than being told, so this is the
# comparison that matters: two independent derivations of one layout.
cat >"$tmp/rtabi.c" <<'RTABI'
#include <stdio.h>
#include <stddef.h>
// The same three facts the runtime's macros state.
#define RT_HEADER_SIZE 16
#define RT_MASK_SLOTS 58
#define RT_SLOT_STRIDE ((long long)sizeof(void*))
int main(void) {
    printf("header=%d slots=%d stride=%lld span=%lld\n", RT_HEADER_SIZE, RT_MASK_SLOTS,
           RT_SLOT_STRIDE, (long long)RT_MASK_SLOTS * RT_SLOT_STRIDE);
    return 0;
}
RTABI
clang -O1 "$tmp/rtabi.c" -o "$tmp/rtabi"
"$tmp/rtabi" >"$tmp/rtabi.out"
diff -u - "$tmp/rtabi.out" <<'EXPECTED'
header=16 slots=58 stride=8 span=464
EXPECTED
# And the macros in the test above are the ones the runtime actually uses, copied here
# only so this file compiles standalone. Verified against the source rather than assumed.
grep -q '^#define RT_HEADER_SIZE 16$' runtime/beans_rt.c
grep -q '^#define RT_MASK_SLOTS 58$' runtime/beans_rt.c
grep -q '^#define RT_SLOT_STRIDE ((long long)sizeof(void\*))$' runtime/beans_rt.c
# Class descriptors carry an optional extended pointer shape between the id and
# method table. Both offsets are byte offsets because an i64 spans two pointer
# slots on a 32-bit target.
grep -q '^#define RT_DESC_ID_SIZE 8$' runtime/beans_rt.c
grep -q '^#define RT_DESC_SHAPE_OFFSET RT_DESC_ID_SIZE$' runtime/beans_rt.c
grep -q '^#define RT_DESC_METHODS_OFFSET (RT_DESC_ID_SIZE + (long long)sizeof(void\*))$' runtime/beans_rt.c
if grep -n 'beans_deinit_sel + 1' runtime/beans_rt.c; then
    echo "the deinit slot is being reached by adding to the selector again" >&2
    exit 1
fi

echo "checking no walker uses its own stride"
# One macro applies the stride, so a walker cannot quietly pick a different one.
# Generic i64-backed slots and extended class shapes now go through helpers of
# their own; keep all three shared paths alive and reject a hand-written stride.
if grep -nE '\*\(void\*\*\)\((\(char\*\))?[A-Za-z_][A-Za-z_0-9]* \+ (8 \* [a-z]+|[a-z]+ \* 8)\)' \
        runtime/beans_rt.c; then
    echo "a pointer-slot walk bypassed RT_SLOT_AT and hardcoded an 8-byte stride" >&2
    exit 1
fi
uses=$(grep -c 'RT_SLOT_AT(' runtime/beans_rt.c)
masked_uses=$(grep -c 'rt_masked_child(' runtime/beans_rt.c)
extended_uses=$(grep -c 'rt_extended_child(' runtime/beans_rt.c)
if [[ "$uses" -lt 8 || "$masked_uses" -lt 6 || "$extended_uses" -lt 3 ]]; then
    echo "pointer walkers stopped using a shared slot helper" >&2
    echo "  RT_SLOT_AT=$uses masked=$masked_uses extended=$extended_uses" >&2
    exit 1
fi

echo "checking Error still works end to end in both backends"
# The layout change is invisible if it is right, so the thing to prove is that nothing
# moved: a kind slug read back, an error with a computed kind, and one nested in a
# container so the destructor walks its mask.
cat >"$tmp/errors.b" <<'ERRORS'
import std.io

fn fails(which: int) -> Result<int> {
    if which == 0 { return err("plain message") }
    if which == 1 { return err("with a kind", "not_found") }
    let part: string = "found"
    return err("computed kind", "not_{part}")
}

fn main() {
    var kinds: List<string> = []
    var i: int = 0
    for i < 3 {
        match fails(i) {
            ok(v) => io.println("unexpected {v}"),
            err(e) => {
                io.println("[{e.msg}] [{e.kind}]")
                kinds.push(e.kind)
            }
        }
        i += 1
    }
    io.println("collected {kinds.len()} kinds, last is {kinds.last().or("?")}")
    // A Result holding an Error inside a list: the generic destructor walks the mask
    // when the list drops, which is where a wrong slot bit would show up as a leak or
    // a crash rather than a wrong answer.
    var boxed: List<Result<int>> = []
    var j: int = 0
    for j < 40 {
        boxed.push(fails(j % 3))
        j += 1
    }
    io.println("boxed {boxed.len()} results")
    boxed.clear()
    io.println("cleared cleanly")
}
ERRORS
./build/beansc run "$tmp/errors.b" >"$tmp/errors.interp"
./build/beansc build "$tmp/errors.b" -o "$tmp/errors" >/dev/null 2>&1
"$tmp/errors" >"$tmp/errors.native"
diff -u "$tmp/errors.interp" "$tmp/errors.native"
diff -u - "$tmp/errors.interp" <<'EXPECTED'
[plain message] []
[with a kind] [not_found]
[computed kind] [not_found]
collected 3 kinds, last is not_found
boxed 40 results
cleared cleanly
EXPECTED
if [[ "$(uname -s)" == Darwin ]]; then
    BEANS_NO_POOL=1 leaks --atExit -- "$tmp/errors" >"$tmp/errors.leaks" 2>&1 || true
    grep -q '0 leaks for 0 total leaked bytes' "$tmp/errors.leaks" || {
        grep -E 'leaks for|leaked bytes' "$tmp/errors.leaks" >&2
        exit 1
    }
fi

echo "checking a class past the inline mask uses its descriptor shape"
# 58 slots is 464 bytes at an 8-byte stride. A pointer beyond that cannot be named by
# the mask at all, so the class needs its extended shape — a silently unwalked field
# is a leak that only shows up under the collector.
cat >"$tmp/wide.b" <<'WIDE'
// 60 string fields puts the last ones past the 58-slot mask.
import std.io

class Marker {
    fn deinit() {
        io.println("last pointer dropped")
    }
}

class Wide {
    f0: string = ""
    f1: string = ""
    f2: string = ""
    f3: string = ""
    f4: string = ""
    f5: string = ""
    f6: string = ""
    f7: string = ""
    f8: string = ""
    f9: string = ""
    f10: string = ""
    f11: string = ""
    f12: string = ""
    f13: string = ""
    f14: string = ""
    f15: string = ""
    f16: string = ""
    f17: string = ""
    f18: string = ""
    f19: string = ""
    f20: string = ""
    f21: string = ""
    f22: string = ""
    f23: string = ""
    f24: string = ""
    f25: string = ""
    f26: string = ""
    f27: string = ""
    f28: string = ""
    f29: string = ""
    f30: string = ""
    f31: string = ""
    f32: string = ""
    f33: string = ""
    f34: string = ""
    f35: string = ""
    f36: string = ""
    f37: string = ""
    f38: string = ""
    f39: string = ""
    f40: string = ""
    f41: string = ""
    f42: string = ""
    f43: string = ""
    f44: string = ""
    f45: string = ""
    f46: string = ""
    f47: string = ""
    f48: string = ""
    f49: string = ""
    f50: string = ""
    f51: string = ""
    f52: string = ""
    f53: string = ""
    f54: string = ""
    f55: string = ""
    f56: string = ""
    f57: string = ""
    f58: string = ""
    f59: string = ""
    last: Marker

    fn init(last: Marker) {
        self.last = last
    }
}
fn main() {
    let w: Wide = new Wide(new Marker())
}
WIDE
./build/beansc build "$tmp/wide.b" -o "$tmp/wide" >"$tmp/wide.log" 2>&1
"$tmp/wide" >"$tmp/wide.out"
grep -qx 'last pointer dropped' "$tmp/wide.out"
grep -q '@.next.classshape' build/wide.ll

echo "checking an oversized inline field keeps its ARC"
cat >"$tmp/wide_field.b" <<'WIDE_FIELD'
import std.io

class Node { tag: int = 0 }

struct Big {
    // The tail lands in slot 58, just outside the inline mask.
    f0: int = 0
    f1: int = 0
    f2: int = 0
    f3: int = 0
    f4: int = 0
    f5: int = 0
    f6: int = 0
    f7: int = 0
    f8: int = 0
    f9: int = 0
    f10: int = 0
    f11: int = 0
    f12: int = 0
    f13: int = 0
    f14: int = 0
    f15: int = 0
    f16: int = 0
    f17: int = 0
    f18: int = 0
    f19: int = 0
    f20: int = 0
    f21: int = 0
    f22: int = 0
    f23: int = 0
    f24: int = 0
    f25: int = 0
    f26: int = 0
    f27: int = 0
    f28: int = 0
    f29: int = 0
    f30: int = 0
    f31: int = 0
    f32: int = 0
    f33: int = 0
    f34: int = 0
    f35: int = 0
    f36: int = 0
    f37: int = 0
    f38: int = 0
    f39: int = 0
    f40: int = 0
    f41: int = 0
    f42: int = 0
    f43: int = 0
    f44: int = 0
    f45: int = 0
    f46: int = 0
    f47: int = 0
    f48: int = 0
    f49: int = 0
    f50: int = 0
    f51: int = 0
    f52: int = 0
    f53: int = 0
    f54: int = 0
    f55: int = 0
    f56: int = 0
    f57: int = 0
    tail: Node
}

class Owner {
    slot: Big = Big { tail: new Node() }
}

fn main() {
    let owner: Owner = new Owner()
    var i: int = 0
    for i < 1000 {
        owner.slot = Big { tail: new Node() }
        i += 1
    }
    io.println("done")
}
WIDE_FIELD
./build/beansc build --emit ir "$tmp/wide_field.b" >"$tmp/wide_field.log" 2>&1
grep -q 'field.assign.old' build/wide_field.ll
clang -O1 -DBEANS_ARC_STATS -Wno-override-module \
    build/wide_field.ll build/beans_rt.c -lm -o "$tmp/wide_field"
"$tmp/wide_field" >"$tmp/wide_field.out" 2>"$tmp/wide_field.stats"
grep -qx 'done' "$tmp/wide_field.out"
grep -Eq 'beans arc stats: allocations=1002 .* frees=1002 ' \
    "$tmp/wide_field.stats"

echo "ok object ABI: one stride, Error layout, extended shapes, and oversized inline ARC"
