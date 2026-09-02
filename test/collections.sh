#!/usr/bin/env bash
# std.collections: Set, Deque, PriorityQueue and SortedMap, plus the
# fmt.StringBuilder. Each structure is driven through a randomized operation
# stream and checked against an independent linear model in
# test/cases/collections_models.b; the golden pins the result and both backends
# must print it byte for byte. Two sanitizer lanes then run: the leak-clean
# subset (collections_leakcheck.b) under full ASan + UBSan + LeakSanitizer, and
# the whole model — which exercises SortedMap.remove — under the same three.
# On Linux ASan bundles LeakSanitizer and runs it by default, so the
# check greps for AddressSanitizer, UndefinedBehaviorSanitizer and LeakSanitizer
# and treats a non-zero exit as failure — a leak here must be loud, not silent.
# The bounded element/key rules — Clone for every value read back, Order for a
# sorted key — are refused at the type with a message about the program.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-collections.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking Set, Deque, PriorityQueue, SortedMap and StringBuilder against linear models"
./build/beansc run test/cases/collections_models.b >"$tmp/interp"
./build/beansc build test/cases/collections_models.b -o "$tmp/native" >"$tmp/build"
"$tmp/native" >"$tmp/native.out"
# Golden byte for byte on both backends, and the two backends against each other.
diff -u test/cases/collections_models.out "$tmp/interp"
diff -u "$tmp/interp" "$tmp/native.out"
grep -q '^total errors 0$' "$tmp/interp"

echo "checking the leak-clean collections under ASan, UBSan and LeakSanitizer"
./build/beansc run   test/cases/collections_leakcheck.b >"$tmp/leak.interp"
./build/beansc build test/cases/collections_leakcheck.b -o "$tmp/leak.native" \
    >"$tmp/leak.build"
"$tmp/leak.native" >"$tmp/leak.native.out"
diff -u "$tmp/leak.interp" "$tmp/leak.native.out"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module build/collections_leakcheck.ll build/beans_rt.c -lm \
    -o "$tmp/leak.asan"
# This program frees everything it drops, so LeakSanitizer (default on Linux)
# must stay silent; a leak here is a real regression in Set, Deque,
# PriorityQueue, the builder, or SortedMap's non-removing paths.
if ! BEANS_NO_POOL=1 "$tmp/leak.asan" >"$tmp/leak.asan.out" 2>"$tmp/leak.asan.err"
then
    cat "$tmp/leak.asan.err" >&2
    echo "collections_leakcheck exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/leak.asan.err"; then
    cat "$tmp/leak.asan.err" >&2
    exit 1
fi
diff -u "$tmp/leak.interp" "$tmp/leak.asan.out"

echo "checking the full model, incl. SortedMap.remove, under ASan, UBSan and LeakSanitizer"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module build/collections_models.ll build/beans_rt.c -lm \
    -o "$tmp/model.asan"
# This lane used to run with detect_leaks=0 because SortedMap.remove leaked in
# the native ARC codegen (#60). #60 has landed, so the structural remove path
# is leak-checked like everything else: LeakSanitizer is on by default under
# ASan on Linux, and a leak here fails the run.
if ! BEANS_NO_POOL=1 "$tmp/model.asan" \
        >"$tmp/model.asan.out" 2>"$tmp/model.asan.err"; then
    cat "$tmp/model.asan.err" >&2
    echo "collections_models exited non-zero under ASan/UBSan" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/model.asan.err"; then
    cat "$tmp/model.asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/model.asan.out"

echo "checking what a container does while it drops what it owns"
./build/beansc run   test/cases/collections_teardown.b >"$tmp/teardown.interp"
./build/beansc build test/cases/collections_teardown.b -o "$tmp/teardown.native" \
    >"$tmp/teardown.build"
"$tmp/teardown.native" >"$tmp/teardown.native.out"
diff -u test/cases/collections_teardown.out "$tmp/teardown.interp"
diff -u "$tmp/teardown.interp" "$tmp/teardown.native.out"
# A tear is a container answering its old shape over storage it has already
# released; an inconsistent answer is `remove` reporting what it did not do.
grep -q '^total tears 0$' "$tmp/teardown.interp"
grep -q '^consistent answers 1 of 1$' "$tmp/teardown.interp"

echo "checking a move-only value is refused at the type"
if ./build/beansc check test/cases/collections_move_only_bad.b \
    >"$tmp/clone.bad" 2>&1; then
    echo "a collection accepted a move-only element" >&2
    exit 1
fi
grep -q "Set needs T implements Clone, got Bytes" "$tmp/clone.bad"
grep -q "Deque needs T implements Clone, got Bytes" "$tmp/clone.bad"
grep -q "SortedMap needs V implements Clone, got Bytes" "$tmp/clone.bad"

echo "checking an unordered key is refused at the type"
if ./build/beansc check test/cases/collections_order_key_bad.b \
    >"$tmp/order.bad" 2>&1; then
    echo "a sorted structure accepted a key with no order" >&2
    exit 1
fi
grep -q "SortedMap needs K implements Order, got main.Key" "$tmp/order.bad"
grep -q "PriorityQueue needs P implements Order, got main.Key" "$tmp/order.bad"

echo "ok std.collections models, both ASan lanes, and the element/key rules"
