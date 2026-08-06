#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-"$PWD/build/beansc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-c-union.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking inline C-layout union parity"
"$beansc" run examples/c_layout_unions.b >"$tmp/interp"
"$beansc" build examples/c_layout_unions.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/c_layout_union.out "$tmp/interp"
diff -u test/cases/c_layout_union.out "$tmp/native.out"
grep -q '%bs.main$Word = type {i32}' build/c_layout_unions.ll
grep -q '%bs.main$AlignedBlock = type {i64, \[8 x i8\]}' build/c_layout_unions.ll
if ! grep -q '^define %bs.main$Word @b_main$passthrough(%bs.main$Word ' \
        build/c_layout_unions.ll; then
    awk '
        $0 == "; main.passthrough" {
            getline
            if ($0 ~ /^define %bs[.]main[$]Word @[^ (]+[(]%bs[.]main[$]Word /) found = 1
        }
        END { exit !found }
    ' build/c_layout_unions.ll
fi

echo "checking union compile failures"
if "$beansc" check test/cases/c_layout_union_attribute_bad.b >"$tmp/attribute" 2>&1; then
    echo "c_layout_union_attribute_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q 'union requires extern "C"' "$tmp/attribute"
if "$beansc" check test/cases/c_layout_union_bad.b >"$tmp/bad" 2>&1; then
    echo "c_layout_union_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q 'unions need at least one field' "$tmp/bad"
grep -q 'struct/union fields need inline scalar, RawPtr, fixed-array, or nested struct storage' "$tmp/bad"
grep -q 'generic unions are not available yet' "$tmp/bad"
grep -q 'union fields cannot have defaults' "$tmp/bad"
grep -q 'union methods are not available yet' "$tmp/bad"
grep -q 'union initialization requires unsafe' "$tmp/bad"
grep -q 'union field access requires unsafe' "$tmp/bad"
grep -q 'union initializer sets exactly one field, got 0' "$tmp/bad"
grep -q 'union initializer sets exactly one field, got 2' "$tmp/bad"
grep -q 'union fields only support direct assignment for now' "$tmp/bad"

echo "ok overlapping union fields, unsafe access, raw memory, and inline ABI"
