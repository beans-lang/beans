#!/usr/bin/env bash
# The order a dying object releases its fields, and the order a container
# publishes itself before releasing what it held (beans #82, #83).
#
# #82:
# The interpreter had a canonical order written down -- the object's own class
# first, fields in reverse declaration order, then each base up the chain --
# and reached it only for objects whose field types spelled a class name at the
# head. A field typed as a generic parameter, an Option, a Result, a List, a
# Map or a struct missed that test, so those objects fell through to whatever
# order construction happened to write their fields in: derived-before-base for
# defaults, initializer-statement order for the rest. The native backend always
# used the layout order. One checked program, two release orders.
#
# The rule now is storage-shaped rather than predicate-shaped: an object's
# field slots are taken in the order a native build lays them out -- base class
# first, declaration order within each class -- when the object is built, so
# the host runtime's own back-to-front release of them IS the canonical order.
# Field defaults evaluate in that same order, which is what the native backend
# already did.
#
# #83: `clear()` on a Map or an OrderedMap stored a fresh key list, releasing
# every class key, while the value map -- the field `len`, `is_empty` and
# `contains_key` all read -- was still full. spec/CONCURRENCY.md says the
# opposite and the native backend does the opposite: the storage is detached
# and an empty container published before the first element's release. Both
# halves of an entry are set aside first now, so no accessor can answer out of
# the half the clear has not reached, and the second store can no longer wipe
# what a deinit put back.
#
# What this pins:
#   1. every field shape releases in the canonical order, on both backends,
#      against one golden file (test/cases/release_order.b);
#   2. the cascade stays iterative -- a 200k-link generic chain is dropped at
#      once and must not smash the host stack on either backend
#      (test/cases/release_order_deep.b), and the same holds for a chain whose
#      class declares a `deinit`, which takes the host-wrapper path the silent
#      chain never does (test/cases/release_order_deinit_deep.b, issue #96);
#   3. a container is empty by every accessor before the first element release
#      runs, for class keys as well as class values, over clear, remove,
#      reassignment and nested containers, at n = 1, 2 and 6
#      (test/cases/container_settle.b).
#
# The split this note used to call out -- a Map dropped or reassigned while it
# holds class keys AND class values releasing all values and then all keys in
# the interpreter, where native releases each entry's value before its own key
# -- is fixed (#97): the tree map stores each entry as one value owning both
# halves, so the host cascade interleaves them the way it does for a native map.
# test/cases/parity/map_release_order.b pins it against the native backend.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-release-order.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# 1. Field release order and default evaluation order: one golden, both
#    backends, byte for byte.
echo "checking field release order for every field shape"
"$beansc" run test/cases/release_order.b >"$tmp/order.interp"
"$beansc" build test/cases/release_order.b -o "$tmp/order.native" \
    >"$tmp/order.build" 2>&1
"$tmp/order.native" >"$tmp/order.native.out"
diff -u test/cases/release_order.out "$tmp/order.interp"
diff -u test/cases/release_order.out "$tmp/order.native.out"

# 2. The cascade is iterative. examples/deep.b pins this for a monomorphic
#    class; a generic one is the shape that made the field-type test miss, so
#    it is the shape a future "just widen the predicate" fix would break --
#    the recursive wrapper path runs one host frame per link.
echo "checking a 200k-link generic chain drops without recursing"
"$beansc" run test/cases/release_order_deep.b >"$tmp/deep.interp"
"$beansc" build test/cases/release_order_deep.b -o "$tmp/deep.native" \
    >"$tmp/deep.build" 2>&1
"$tmp/deep.native" >"$tmp/deep.native.out"
printf 'alive -1\n' >"$tmp/deep.expected"
diff -u "$tmp/deep.expected" "$tmp/deep.interp"
diff -u "$tmp/deep.expected" "$tmp/deep.native.out"

# 2b. The same cascade with a `deinit`. release_order_deep.b's class is silent,
#     so it takes the no-wrapper path and never touches the recursive one. An
#     object that declares a `deinit` gets a host wrapper, and the wrapper used
#     to release the object's fields by hand -- one host frame per link -- so a
#     deep chain of them overflowed the interpreter's stack where the native
#     backend dropped it iteratively (issue #96). The tally proves every link's
#     deinit ran; `id == 0` is the deepest node, so its line prints only if the
#     drop reached the bottom of the chain in constant host stack.
echo "checking a 200k-link chain WITH a deinit drops without recursing"
"$beansc" run test/cases/release_order_deinit_deep.b >"$tmp/dd.interp"
"$beansc" build test/cases/release_order_deinit_deep.b -o "$tmp/dd.native" \
    >"$tmp/dd.build" 2>&1
"$tmp/dd.native" >"$tmp/dd.native.out"
diff -u test/cases/release_order_deinit_deep.out "$tmp/dd.interp"
diff -u test/cases/release_order_deinit_deep.out "$tmp/dd.native.out"

# 3. A container settles before it releases what it owned -- keys included.
echo "checking a container is empty before the first element release"
"$beansc" run test/cases/container_settle.b >"$tmp/settle.interp"
"$beansc" build test/cases/container_settle.b -o "$tmp/settle.native" \
    >"$tmp/settle.build" 2>&1
"$tmp/settle.native" >"$tmp/settle.native.out"
diff -u test/cases/container_settle.out "$tmp/settle.interp"
diff -u test/cases/container_settle.out "$tmp/settle.native.out"

echo "ok field release order, iterative cascade (silent and deinit), container settle"
