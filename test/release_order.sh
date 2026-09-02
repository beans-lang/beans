#!/usr/bin/env bash
# The order a dying object releases its fields (beans #82).
#
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
# What this pins:
#   1. every field shape releases in the canonical order, on both backends,
#      against one golden file (test/cases/release_order.b);
#   2. the cascade stays iterative -- a 200k-link generic chain is dropped at
#      once and must not smash the host stack on either backend
#      (test/cases/release_order_deep.b).
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

echo "ok field release order and iterative cascade"
