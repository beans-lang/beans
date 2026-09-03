#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-moves.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/move_ok.b >"$tmp/interp"
./build/beansc build test/cases/move_ok.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/move_ok.out "$tmp/interp"
diff -u test/cases/move_ok.out "$tmp/native.out"
grep -q '^; main.swap$' build/move_ok.ll
grep -q '^define void @.next.fn[0-9]*(ptr %l0, ptr %l1)' \
    build/move_ok.ll
grep -q '^; main.replace$' build/move_ok.ll
grep -q '^define void @.next.fn[0-9]*(ptr %l0, ptr %arg1)' \
    build/move_ok.ll

if ./build/beansc check test/cases/move_bad.b >"$tmp/bad" 2>&1; then
    echo "move_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "use of moved value 'item'" "$tmp/bad"
grep -q "value 'item' may have been moved" "$tmp/bad"
grep -q "can't move borrowed binding 'item'" "$tmp/bad"
grep -q "can't move outer value 'item' from a loop or escaping closure" "$tmp/bad"
grep -q "move needs a local name" "$tmp/bad"

if ./build/beansc check test/cases/box_move_bad.b >"$tmp/box-bad" 2>&1; then
    echo "box_move_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "because Box<int> is move-only" "$tmp/box-bad"
grep -q "List.push needs 'move second'" "$tmp/box-bad"

# A move-only map value comes back as the map's own, which makes the binding a
# borrow of the map. One reader at a time: two live ones would be two mutating
# names for one value, which is the whole thing move-only rules out.
./build/beansc run test/cases/map_borrow_ok.b >"$tmp/borrow.interp"
./build/beansc build test/cases/map_borrow_ok.b \
    -o "$tmp/borrow.native" >"$tmp/borrow.build" 2>&1
"$tmp/borrow.native" >"$tmp/borrow.native.out"
diff -u test/cases/map_borrow_ok.out "$tmp/borrow.interp"
diff -u test/cases/map_borrow_ok.out "$tmp/borrow.native.out"

if ./build/beansc check test/cases/map_borrow_bad.b \
    >"$tmp/borrow-bad" 2>&1; then
    echo "map_borrow_bad.b unexpectedly passed" >&2
    exit 1
fi
# nested, deeper in a block, and for a move-only class value
test "$(grep -c "already read into 'first'" "$tmp/borrow-bad")" -eq 3
grep -q "one live reader at a time" "$tmp/borrow-bad"
grep -q "can't move borrowed binding 'held'" "$tmp/borrow-bad"
grep -q "can't copy a move-only map value by index" "$tmp/borrow-bad"

echo "ok one live reader at a time for a move-only map value"
grep -q "some needs 'move second'" "$tmp/box-bad"
grep -q "new Shared needs 'move second'" "$tmp/box-bad"

if ./build/beansc check test/cases/arena_move_bad.b >"$tmp/arena-bad" 2>&1; then
    echo "arena_move_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "because Arena<int> is move-only" "$tmp/arena-bad"

if ./build/beansc check test/cases/collection_move_bad.b >"$tmp/collection-bad" 2>&1; then
    echo "collection_move_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "return needs 'move values' because List<int> is move-only" "$tmp/collection-bad"
grep -q "binding 'copied' needs 'move values' because List<int> is move-only" "$tmp/collection-bad"
grep -q "binding 'copied_map' needs 'move map' because Map<string, int> is move-only" "$tmp/collection-bad"
grep -q "List<List<int>> has no method 'clone'" "$tmp/collection-bad"
grep -q "consume.*move argument 1 needs 'move values'" "$tmp/collection-bad"
grep -q "has ownership parameters and cannot be stored as a value yet" "$tmp/collection-bad"
grep -q "because main.Packet is move-only" "$tmp/collection-bad"
grep -q "inout argument 1 must be 'inout var_name'" "$tmp/collection-bad"
grep -q "inout needs var, but 'fixed' is a let" "$tmp/collection-bad"
grep -q "overlapping inout arguments for 'left'" "$tmp/collection-bad"
grep -q "inout is only valid for an inout call argument" "$tmp/collection-bad"
grep -q "closure cannot capture inout parameter 'value'" "$tmp/collection-bad"
grep -q "changes ownership mode of argument 1" "$tmp/collection-bad"

# A struct that reaches itself has no finite layout, and that is reported on
# its own. Checking then carries on, so the move-only question still gets asked
# about a type whose fields loop — it has to come back with an answer rather
# than descend the cycle until the stack runs out. Stage 0 is where that walk
# is C++ recursion, so it is checked too when the bootstrap is present; forks
# build without the private submodule and skip it.
for compiler in ./build/beansc; do
    [[ -x "$compiler" ]] || continue
    out="$tmp/recursive-bad.$(basename "$compiler")"
    if "$compiler" check test/cases/move_only_recursive_bad.b >"$out" 2>&1; then
        echo "move_only_recursive_bad.b unexpectedly passed $compiler" >&2
        exit 1
    fi
    grep -q "recursive inline layout through field 'next'" "$out"
    grep -q "recursive inline layout through field 'ping'" "$out"
done

# Ownership wrappers must agree in both checkers. This covers typed `none`,
# adjacent generic closers, generic fieldless variants, interface declaration
# semicolons, and the move-only paths that used to turn borrows into aliases.
for compiler in ./build/beansc; do
    [[ -x "$compiler" ]] || continue
    "$compiler" check test/cases/ownership_edges_ok.b \
        >"$tmp/ownership-ok.$(basename "$compiler")" 2>&1
    out="$tmp/ownership-bad.$(basename "$compiler")"
    if "$compiler" check test/cases/ownership_edges_bad.b >"$out" 2>&1; then
        echo "ownership_edges_bad.b unexpectedly passed $compiler" >&2
        exit 1
    fi
    grep -q "return needs 'move source'" "$out"
    grep -q "? needs 'move source'" "$out"
    grep -q "cannot use move-only List<int> for generic T" "$out"
    grep -q "filter needs 'move option_source'" "$out"
    grep -q "or default needs 'move default_value'" "$out"
    grep -q "recover needs 'move result_value'" "$out"
    grep -q "err needs 'move custom_error_source'" "$out"
    grep -q "map needs 'move result_error'" "$out"
    grep -q "Box<List<int>> has no method 'get'" "$out"
    grep -q "List<List<int>> has no method 'slice'" "$out"
    grep -q "can't copy a move-only map value by index" "$out"
    grep -q "Map key cannot be move-only" "$out"
    # One rule, one sentence. The written-out map type and a literal whose
    # type nothing else pins down are two call sites of the same check, and
    # they used to answer differently. Counting rather than matching is the
    # point: a reason added to one site and forgotten on the other leaves the
    # grep above green and drops one of these three.
    test "$(grep -c "a map owns a copy of every key and keys() hands copies back" "$out")" -eq 3
    # and the Bytes hint on both of the two Bytes-keyed sites
    test "$(grep -c "key by string and convert with Bytes.to_string()" "$out")" -eq 2
    grep -q "Arena.add needs 'move arena_value'" "$out"
    grep -q "Channel.send needs 'move message'" "$out"
done

./build/beansc run test/cases/ownership_edges_ok.b >"$tmp/ownership-interp"
./build/beansc build test/cases/ownership_edges_ok.b \
    -o "$tmp/ownership-native" >"$tmp/ownership-build" 2>&1
"$tmp/ownership-native" >"$tmp/ownership-native.out"
diff -u test/cases/ownership_edges_ok.out "$tmp/ownership-interp"
diff -u test/cases/ownership_edges_ok.out "$tmp/ownership-native.out"

echo "ok move, wrappers, generic ownership, branches, and use-after-move errors"
