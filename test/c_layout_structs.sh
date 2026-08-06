#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-c-layout.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking inline C-layout struct parity"
"$beansc" run examples/c_layout_structs.b >"$tmp/interp"
"$beansc" build examples/c_layout_structs.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/c_layout_struct.out "$tmp/interp"
diff -u test/cases/c_layout_struct.out "$tmp/native.out"
grep -q '%bs.main$Packet = type {i8, i32, float, i1}' build/c_layout_structs.ll
grep -q '%bs.main$Link = type {i32, ptr}' build/c_layout_structs.ll
grep -q '%bs.main$Pair = type {i16, \[3 x i8\]}' build/c_layout_structs.ll
grep -q '%bs.main$Frame = type {%bs.main$Pair, \[2 x i32\], \[2 x ptr\]}' build/c_layout_structs.ll
if ! grep -q '^define %bs.main$Packet @b_main$bumped(%bs.main$Packet ' \
        build/c_layout_structs.ll; then
    awk '
        $0 == "; main.bumped" {
            getline
            if ($0 ~ /^define %bs[.]main[$]Packet @[^ (]+[(]%bs[.]main[$]Packet /) found = 1
        }
        END { exit !found }
    ' build/c_layout_structs.ll
fi

echo "checking struct compile failures"
if "$beansc" check test/cases/c_layout_attribute_bad.b >"$tmp/attribute" 2>&1; then
    echo "c_layout_attribute_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q '@c_layout was removed' "$tmp/attribute"
if "$beansc" check test/cases/c_layout_struct_bad.b >"$tmp/bad" 2>&1; then
    echo "c_layout_struct_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q 'structs need at least one field' "$tmp/bad"
grep -q 'struct/union fields need inline scalar, RawPtr, fixed-array, or nested struct storage' "$tmp/bad"
grep -q "recursive inline layout through field 'next' has no finite size" "$tmp/bad"
grep -q 'generic structs are not available yet' "$tmp/bad"
grep -q 'structs cannot inherit' "$tmp/bad"
grep -q 'struct methods are not available yet' "$tmp/bad"
grep -q "is a let — its fields can't be reassigned" "$tmp/bad"
grep -q 'RawPtr only supports inline scalars, RawPtr, fixed arrays, and extern "C" struct/union values' "$tmp/bad"

echo "ok inline struct copies, target layout, raw memory, slices, and native ABI"
