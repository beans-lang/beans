#!/usr/bin/env bash
# `Order` and `Eq` on a float are IEEE 754 totalOrder and bit equality, while
# the operators stay IEEE (issue #84, spec/SYNTAX.md "Number rules").
#
# The transcript is checked three ways on purpose. Interpreter against native
# catches the half of #84 where the two disagreed — a NaN map key was
# write-only natively and every re-insert appended. Both against a committed
# golden catches the other half, where both backends agreed and both were
# wrong: a partial order silently mis-sorts and silently overwrites, and no
# parity diff can see that. ASan covers the runtime's new key path.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-float-total-order.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking float/f32 totalOrder in containers and sorts"
./build/beansc run test/cases/float_total_order.b >"$tmp/interp"
./build/beansc build test/cases/float_total_order.b -o "$tmp/native" >"$tmp/build"
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/float_total_order.out "$tmp/interp"
diff -u "$tmp/interp" "$tmp/native.out"

# Guard the two rules the transcript exists for, so a regenerated golden that
# quietly went back to IEEE still fails here.
grep -q '^nan == nan: false$' "$tmp/interp"
grep -q '^nan < 1.0: false$' "$tmp/interp"
grep -q '^-0.0 == 0.0: true$' "$tmp/interp"
grep -q '^issue case \[1, 2, 3, +nan\]$' "$tmp/interp"
grep -q '^whole line \[-nan, -inf, -1, -0.0, +0.0, 1, inf, +nan\]$' "$tmp/interp"
grep -q '^after 2nd NaN insert: len=2 get=some(100)$' "$tmp/interp"
grep -q '^1000 inserts -> len=1 get=some(999)$' "$tmp/interp"
grep -q '^less(1.0, +nan): true$' "$tmp/interp"
grep -q '^alike(+nan, +nan): true$' "$tmp/interp"
grep -q '^bool less(false, true): true$' "$tmp/interp"
grep -q '^simd(+nan) == simd(+nan): false$' "$tmp/interp"
grep -q '^SortedMap len=4 keys=\[1, 2, 3, +nan\] values=\[1, 2, 3, 99\]$' \
    "$tmp/interp"
grep -q '^get(+nan)=some(99) get(2.0)=some(2) contains(+nan)=true$' \
    "$tmp/interp"
grep -q '^PriorityQueue drain=-nan, -inf, -0.0, +0.0, one, two, inf, +nan$' \
    "$tmp/interp"
grep -q '^Set len=4 contains(+nan)=true' "$tmp/interp"
grep -q '^get(+nan)=some(100) get(-nan)=some(101) get(payload)=some(102)$' \
    "$tmp/interp"
# Equal aggregate keys must hash equal, or a lookup lands in the wrong bucket
# and misses an entry that is sitting in the table. These maps are all past
# MAP_LINEAR_MAX, so the index is live and every read below actually hashes.
grep -q '^struct keys len=35$' "$tmp/interp"
grep -q '^fresh get(+nan)=some(100) get(-nan)=some(101) get(payload)=some(102)$' \
    "$tmp/interp"
grep -q '^fresh get(-0.0)=some(103) get(+0.0)=some(104) get(7.0)=some(7)$' \
    "$tmp/interp"
grep -q '^struct re-insert: len=35 ' "$tmp/interp"
grep -q '^f32 struct keys len=34 get(+nan)=some(100) get(-nan)=some(101)$' \
    "$tmp/interp"
grep -q '^array keys len=34 get(+nan)=some(100) get(-nan)=some(101)$' \
    "$tmp/interp"
grep -q '^array re-insert: len=34 get=some(200)$' "$tmp/interp"
grep -q '^option keys len=34 get(+nan)=some(100) get(-nan)=some(101)$' \
    "$tmp/interp"
grep -q '^enum keys len=34 get(+nan)=some(100) get(-nan)=some(101)$' \
    "$tmp/interp"
grep -q '^with -nan and both zeros: len=7 keys=\[-nan, -0.0, +0.0, 1, 2, 3, +nan\]$' \
    "$tmp/interp"

echo "checking the runtime key path under AddressSanitizer"
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/float_total_order.ll build/beans_rt.c -lm -o "$tmp/asan"
# A leak is a sanitizer failure like any other: LeakSanitizer rides inside
# ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
# the status before reading the report, or this dies under `set -e` with the
# report still unread in the capture file.
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    echo "float_total_order exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "float total order ok"
