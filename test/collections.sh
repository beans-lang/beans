#!/usr/bin/env bash
# Check collection behavior against linear models on both backends, then run
# leak-clean and full suites under ASan, UBSan, and LeakSanitizer.
# Bounded element and key requirements are also checked at compile time.
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
BEANS_SANITIZE=address,undefined ./build/beansc llvm "test/cases/collections_leakcheck.b" \
    >"$tmp/collections_leakcheck.sanitize-address-undefined.ll"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module "$tmp/collections_leakcheck.sanitize-address-undefined.ll" build/beans_rt.c -lm \
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
BEANS_SANITIZE=address,undefined ./build/beansc llvm "test/cases/collections_models.b" \
    >"$tmp/collections_models.sanitize-address-undefined.ll"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module "$tmp/collections_models.sanitize-address-undefined.ll" build/beans_rt.c -lm \
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
# Under `run`, the checker and this case share a collector. Its parked live
# objects determine whether the probes cross an adaptive threshold (#197).
# Require observation on the isolated native leg, and compare every other
# assertion against the golden on both legs. Never re-pin a false observation
# into the golden: disabling collection must still fail the native check.
diff -u test/cases/collections_teardown.out "$tmp/teardown.native.out"
sed '/^\(crossover\|priorityqueue\|sortedmap\) observed under collection: /d' \
    test/cases/collections_teardown.out >"$tmp/teardown.expected"
sed '/^\(crossover\|priorityqueue\|sortedmap\) observed under collection: /d' \
    "$tmp/teardown.interp" >"$tmp/teardown.checked"
diff -u "$tmp/teardown.expected" "$tmp/teardown.checked"
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

echo "checking required and optional collection access on both backends"
./build/beansc run test/cases/collection_access.b >"$tmp/access.interp"
./build/beansc build test/cases/collection_access.b -o "$tmp/access.native" \
    >"$tmp/access.build" 2>&1
"$tmp/access.native" >"$tmp/access.native.out"
diff -u test/cases/collection_access.out "$tmp/access.interp"
diff -u "$tmp/access.interp" "$tmp/access.native.out"
# Optional reads of inline structs must retain owned fields after the source
# is dropped. Empty and invalid reads must never touch backing storage.
BEANS_SANITIZE=address,undefined ./build/beansc llvm test/cases/collection_access.b \
    >"$tmp/access.ll"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module "$tmp/access.ll" build/beans_rt.c -lm -o "$tmp/access.asan"
if ! BEANS_NO_POOL=1 "$tmp/access.asan" >"$tmp/access.asan.out" 2>"$tmp/access.asan.err"; then
    cat "$tmp/access.asan.err" >&2
    echo "collection access exited non-zero under the sanitizers" >&2
    exit 1
fi
diff -u "$tmp/access.interp" "$tmp/access.asan.out"
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' "$tmp/access.asan.err"; then
    cat "$tmp/access.asan.err" >&2
    exit 1
fi

if ./build/beansc check test/cases/collection_access_bad.b >"$tmp/access.bad" 2>&1; then
    echo "optional access bypassed its type or unsafe requirement" >&2
    exit 1
fi
test "$(grep -c 'expected int, got Option<int>' "$tmp/access.bad")" -eq 3
grep -q 'expected i32, got Option<i32>' "$tmp/access.bad"
grep -q 'Slice.get requires unsafe' "$tmp/access.bad"
grep -q "byte index assignment only supports '='" "$tmp/access.bad"

echo "ok collections, required/optional access, sanitizers, and element/key rules"
