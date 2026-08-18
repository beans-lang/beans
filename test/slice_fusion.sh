#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-slice-fusion.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/slice_fusion.b >"$tmp/interp"
./build/beansc build test/cases/slice_fusion.b -o "$tmp/native" >/dev/null
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/slice_fusion.out "$tmp/interp"
diff -u test/cases/slice_fusion.out "$tmp/native.out"

./build/beansc mir test/cases/slice_fusion.b >"$tmp/slice.mir"
test "$(grep -c 'iterate_init list_slice' "$tmp/slice.mir")" -eq 1
test "$(grep -c 'builtin_method slice resolved=List' "$tmp/slice.mir")" -eq 1
test "$(grep -c 'builtin_method slice_to_string' "$tmp/slice.mir")" -eq 2
test "$(grep -c 'call ptr @beans_list_slice' build/slice_fusion.ll)" -eq 1
if grep -q 'call ptr @beans_bytes_slice(' build/slice_fusion.ll; then
    echo "temporary Bytes-to-string still allocated a Bytes slice" >&2
    exit 1
fi

for case_name in slice_fusion_oob slice_fusion_bytes_oob; do
    set +e
    ./build/beansc run "test/cases/$case_name.b" >"$tmp/$case_name.interp" 2>&1
    interp_status=$?
    ./build/beansc build "test/cases/$case_name.b" -o "$tmp/$case_name" \
        >/dev/null 2>&1
    build_status=$?
    if [[ "$build_status" -eq 0 ]]; then
        "$tmp/$case_name" >"$tmp/$case_name.native" 2>&1
        native_status=$?
    else
        native_status=0
    fi
    set -e
    if [[ "$interp_status" -eq 0 || "$build_status" -ne 0 || \
          "$native_status" -eq 0 ]]; then
        echo "$case_name did not panic in both backends" >&2
        exit 1
    fi
    diff -u "$tmp/$case_name.interp" "$tmp/$case_name.native"
done

echo "ok safe temporary slices fuse and owned snapshot semantics stay intact"
