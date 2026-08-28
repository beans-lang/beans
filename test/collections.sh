#!/usr/bin/env bash
# std.collections: Set, Deque, PriorityQueue and SortedMap, plus the
# fmt.StringBuilder. Each structure is driven through a randomized operation
# stream and checked against an independent linear model in
# test/cases/collections_models.b; the golden pins the result, both backends
# must print it byte for byte, and an ASan lane runs the same program so a
# reference-counting or bounds bug in a new container surfaces as a real memory
# error rather than a lucky pass. The bounded element/key rules — Clone for
# every value read back, Order for a sorted key — are refused at the type with
# a message about the program, never left to the backend.
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

echo "checking the same program under AddressSanitizer"
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/collections_models.ll build/beans_rt.c -lm -o "$tmp/asan"
BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

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

echo "ok std.collections models, ASan, and the element/key rules"
