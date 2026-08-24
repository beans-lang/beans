#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-map-models.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking Map and OrderedMap against a linear model"
./build/beansc run test/cases/map_models.b >"$tmp/interp"
./build/beansc build test/cases/map_models.b -o "$tmp/native" >"$tmp/build"
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"
grep -q '^map model 0 ' "$tmp/interp"

if ./build/beansc check test/cases/index_compound_bad.b \
    >"$tmp/compound.bad" 2>&1; then
    echo "compound List/Map index assignment passed checking" >&2
    exit 1
fi
grep -q "list index assignment only supports '='" "$tmp/compound.bad"
grep -q "map index assignment only supports '='" "$tmp/compound.bad"

clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/map_models.ll build/beans_rt.c -lm -o "$tmp/asan"
BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "checking direct allocation-free map iteration"
./build/beansc run test/cases/map_iteration.b >"$tmp/iteration.interp"
./build/beansc build test/cases/map_iteration.b \
    -o "$tmp/iteration.native" >"$tmp/iteration.build"
"$tmp/iteration.native" >"$tmp/iteration.out"
diff -u test/cases/map_iteration.out "$tmp/iteration.interp"
diff -u "$tmp/iteration.interp" "$tmp/iteration.out"
if grep -q 'call ptr @beans_map_keys' build/map_iteration.ll; then
    echo "direct map iteration allocated a keys list" >&2
    exit 1
fi

if ./build/beansc check test/cases/map_iteration_bad.b \
    >"$tmp/iteration.bad" 2>&1; then
    echo "invalid map iteration passed checking" >&2
    exit 1
fi
grep -q "map iteration needs key and value bindings" "$tmp/iteration.bad"
grep -q "two loop bindings require Map or OrderedMap" "$tmp/iteration.bad"

if ./build/beansc run test/cases/map_iteration_mutation.b \
    >"$tmp/mutation.interp" 2>&1; then
    echo "interpreter allowed structural map mutation during iteration" >&2
    exit 1
fi
grep -q "map changed during iteration" "$tmp/mutation.interp"
./build/beansc build test/cases/map_iteration_mutation.b \
    -o "$tmp/mutation.native" >"$tmp/mutation.build"
if "$tmp/mutation.native" >"$tmp/mutation.out" 2>&1; then
    echo "native backend allowed structural map mutation during iteration" >&2
    exit 1
fi
grep -q "map changed during iteration" "$tmp/mutation.out"

clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/map_iteration.ll build/beans_rt.c -lm -o "$tmp/iteration.asan"
BEANS_NO_POOL=1 "$tmp/iteration.asan" \
    >"$tmp/iteration.asan.out" 2>"$tmp/iteration.asan.err"
if grep -q 'AddressSanitizer' "$tmp/iteration.asan.err"; then
    cat "$tmp/iteration.asan.err" >&2
    exit 1
fi
diff -u "$tmp/iteration.interp" "$tmp/iteration.asan.out"

echo "ok map models and direct key/value iteration"
