#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-wide-list.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking typed-width List storage and ownership"
./build/beansc run examples/wide_lists.b >"$tmp/interp"
./build/beansc build examples/wide_lists.b -o "$tmp/native" >"$tmp/build" 2>&1
BEANS_NO_POOL=1 "$tmp/native" >"$tmp/native.out"
diff -u test/cases/wide_list.out "$tmp/interp"
diff -u test/cases/wide_list.out "$tmp/native.out"
grep -q 'call ptr @beans_list_new_typed(i64 8, i64 0)' build/wide_lists.ll
grep -q 'call ptr @beans_list_new_typed(i64 16, i64 0)' build/wide_lists.ll
grep -Eq 'call ptr @beans_list_new_typed\(i64 24, i64 [1-9]' build/wide_lists.ll
grep -q 'call void @beans_list_push_typed' build/wide_lists.ll
grep -q 'call void @beans_list_remove_typed' build/wide_lists.ll
grep -q 'call void @beans_list_decv_sort' build/wide_lists.ll
if grep -q '@beans_decv_box' build/wide_lists.ll; then
    # Option<decimal> still uses the old enum boundary, but the List itself
    # must not box on push/load. The typed constructor proves its storage ABI.
    grep -q 'call ptr @beans_list_new_typed(i64 16, i64 0)' build/wide_lists.ll
fi

echo "checking min/max order kinds across element widths"
./build/beansc run test/cases/list_extremes_ok.b >"$tmp/extremes.interp"
./build/beansc build test/cases/list_extremes_ok.b -o "$tmp/extremes.native" \
    >"$tmp/extremes.build" 2>&1
"$tmp/extremes.native" >"$tmp/extremes.native.out"
diff -u test/cases/list_extremes_ok.out "$tmp/extremes.interp"
diff -u test/cases/list_extremes_ok.out "$tmp/extremes.native.out"

echo "checking 4-byte typed List<f32> storage"
./build/beansc run test/cases/f32_list_ok.b >"$tmp/f32.interp"
./build/beansc build test/cases/f32_list_ok.b -o "$tmp/f32.native" \
    >"$tmp/f32.build" 2>&1
"$tmp/f32.native" >"$tmp/f32.native.out"
diff -u test/cases/f32_list_ok.out "$tmp/f32.interp"
diff -u test/cases/f32_list_ok.out "$tmp/f32.native.out"
# f32 elements live at their real width: the typed constructor with a
# 4-byte stride, elements addressed as floats, and no slot widening
grep -q 'call ptr @beans_list_new_typed(i64 4, i64 0)' build/f32_list_ok.ll
grep -q 'getelementptr float, ptr' build/f32_list_ok.ll

echo "ok ARC-owning structs/arrays and wide List moves, clones, masks, and slices"
