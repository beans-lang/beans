#!/usr/bin/env bash
# `for x in xs` over a List means the same thing in both backends (beans #57).
#
# The bug was a semantics split nothing wrote down: the interpreter walked a
# snapshot of the elements taken when the loop started, and the native backend
# re-read the live buffer every step. A body that changed the list it was
# iterating got one answer under `beansc run` and another once it shipped
# native. `test/cases/borrowed_iteration.b` hid it for months because its one
# mutating loop held exactly one element, and at n=1 a snapshot and a live read
# are the same bytes.
#
# The rule now is the one a Map already follows: the loop reads the list
# itself, so replacing an element in place is visible on the turn that reaches
# it, and a structural change (push, pop, insert, remove, clear, reverse, sort,
# sort_by, sort_by_key) stops the loop with `list changed during iteration`
# before the next element is read. This suite pins all three claims:
#
#   1. the allowed cases print one golden file on BOTH backends
#      (test/cases/list_iteration.b, at n = 1, 2, 5 and 40 -- a List starts at
#      capacity 4, so 5 and 40 are past its first reallocation);
#   2. a structural change refuses the loop identically on both backends
#      (test/cases/list_iteration_mutation.b -- byte-for-byte, panic and all);
#   3. the whole (size x mutation x fire-turn) matrix agrees across backends
#      and matches an independent model of the rule
#      (tools/list_iteration_probe.py).
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
# The probe builds a native binary per case, so the gate runs its essential
# sizes (`smoke`); pass `full` to walk the whole matrix.
mode=${1:-smoke}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-list-iteration.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# 1. The allowed cases: one golden, both backends, byte for byte.
"$beansc" run test/cases/list_iteration.b >"$tmp/interp"
"$beansc" build test/cases/list_iteration.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/list_iteration.out "$tmp/interp"
diff -u test/cases/list_iteration.out "$tmp/native.out"

# 1b. A Slice<T> loop reads live memory on both backends: the interpreter now
#     reads through the view each turn instead of snapshotting it when the loop
#     started, so a write to the memory it views (through the owning pointer) is
#     seen -- the same answer the native loop always gave. One golden, both.
"$beansc" run test/cases/slice_live_iteration.b >"$tmp/slice.interp"
"$beansc" build test/cases/slice_live_iteration.b -o "$tmp/slice.native" \
    >"$tmp/slice.build" 2>&1
"$tmp/slice.native" >"$tmp/slice.native.out"
diff -u test/cases/slice_live_iteration.out "$tmp/slice.interp"
diff -u test/cases/slice_live_iteration.out "$tmp/slice.native.out"

# 2. A structural change refuses the loop the same way on both backends. There
#    is no golden: the claim is that the two backends agree, panic message and
#    exit status included, so the native output is diffed against the
#    interpreter's, not against a chosen string.
interp_code=0
"$beansc" run test/cases/list_iteration_mutation.b >"$tmp/mut.interp" 2>&1 \
    || interp_code=$?
"$beansc" build test/cases/list_iteration_mutation.b -o "$tmp/mut.native" \
    >"$tmp/mut.build" 2>&1
native_code=0
"$tmp/mut.native" >"$tmp/mut.native.out" 2>&1 || native_code=$?

diff -u "$tmp/mut.interp" "$tmp/mut.native.out"
if [ "$interp_code" != "$native_code" ]; then
    echo "list_iteration_mutation: exit codes differ" \
         "(interp $interp_code, native $native_code)" >&2
    exit 1
fi
if [ "$interp_code" != 3 ]; then
    echo "list_iteration_mutation: expected a panic (exit 3), got" \
         "$interp_code" >&2
    cat "$tmp/mut.interp" >&2
    exit 1
fi
grep -q "list changed during iteration (push, length 5 -> 6)" \
    "$tmp/mut.interp" || {
    echo "list_iteration_mutation: wrong panic message" >&2
    cat "$tmp/mut.interp" >&2
    exit 1
}

# 2b. A negative reserve is a panic on both backends, not a silent no-op under
#     `beansc run` (issue #58). For List, Map and OrderedMap the two backends
#     must agree, panic message and exit status alike.
reserve_parity() {
    name="$1"
    decl="$2"
    cat >"$tmp/$name.b" <<BEANS
import std.io
fn main() {
    var c: $decl
    c.reserve(-1)
    io.println("survived")
}
BEANS
    rc_i=0
    "$beansc" run "$tmp/$name.b" >"$tmp/$name.interp" 2>&1 || rc_i=$?
    "$beansc" build "$tmp/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    rc_n=0
    "$tmp/$name.native" >"$tmp/$name.native.out" 2>&1 || rc_n=$?
    diff -u "$tmp/$name.interp" "$tmp/$name.native.out"
    if [ "$rc_i" != "$rc_n" ]; then
        echo "$name reserve(-1): exit codes differ (interp $rc_i, native $rc_n)" >&2
        exit 1
    fi
    if [ "$rc_i" != 3 ]; then
        echo "$name reserve(-1): expected a panic (exit 3), got $rc_i" >&2
        cat "$tmp/$name.interp" >&2
        exit 1
    fi
    grep -q "negative reserve capacity -1" "$tmp/$name.interp" || {
        echo "$name reserve(-1): wrong panic message" >&2
        cat "$tmp/$name.interp" >&2
        exit 1
    }
}
reserve_parity list_reserve "List<int> = [1, 2, 3]"
reserve_parity map_reserve "Map<int,int> = {}"
reserve_parity omap_reserve "OrderedMap<int,int> = {}"

# 3. The differential probe: every size and mutation, both backends, against an
#    independent model of the rule. A final-state trace cannot see this class of
#    bug, so the probe compares the sequence the loop body observed.
BEANSC="$beansc" python3 tools/list_iteration_probe.py "$mode"

echo "list iteration: golden, slice live-read, mutation panic, reserve parity and differential probe all agree ($mode)"
