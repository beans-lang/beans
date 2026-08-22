#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-raw-slice.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking raw slice value and ABI parity"
./build/beansc run examples/raw_slices.b >"$tmp/interp"
./build/beansc build examples/raw_slices.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/raw_slice.out "$tmp/interp"
diff -u test/cases/raw_slice.out "$tmp/native.out"
grep -q 'insertvalue {ptr, i64}' build/raw_slices.ll

echo "checking raw slice bounds parity"
set +e
./build/beansc run test/cases/raw_slice_oob.b >"$tmp/oob.interp" 2>&1
interp_status=$?
./build/beansc build test/cases/raw_slice_oob.b -o "$tmp/oob.native" \
    >"$tmp/oob.build" 2>&1
build_status=$?
if [[ "$build_status" -eq 0 ]]; then
    "$tmp/oob.native" >"$tmp/oob.native.out" 2>&1
    native_status=$?
else
    native_status=0
fi
set -e
if [[ "$interp_status" -eq 0 || "$build_status" -ne 0 || "$native_status" -eq 0 ]]; then
    echo "raw slice bounds test did not panic in both backends" >&2
    exit 1
fi
diff -u "$tmp/oob.interp" "$tmp/oob.native.out"
grep -q 'slice index 2 out of range (len 2)' "$tmp/oob.interp"

echo "checking stable counted-loop bounds removal"
./build/beansc mir test/cases/bounds_elision.b >"$tmp/bounds.mir"
./build/beansc run test/cases/bounds_elision.b >"$tmp/bounds.interp"
./build/beansc build test/cases/bounds_elision.b -o "$tmp/bounds.native" \
    >"$tmp/bounds.build" 2>&1
"$tmp/bounds.native" >"$tmp/bounds.native.out"
diff -u test/cases/bounds_elision.out "$tmp/bounds.interp"
diff -u test/cases/bounds_elision.out "$tmp/bounds.native.out"
test "$(grep -c 'bounds-elided' "$tmp/bounds.mir")" -eq 1

function_body() {
    local name=$1
    local destination=$2
    awk -v marker="; main.$name" '
        $0 == marker { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' build/bounds_elision.ll >"$destination"
}

function_body stable "$tmp/stable.ll"
function_body negative_start "$tmp/negative.ll"
function_body increment_first "$tmp/increment-first.ll"
grep -q 'load i32, ptr .* align 4' "$tmp/stable.ll"
if grep -q 'beans_panic_slice_index\|slice.index.ok' "$tmp/stable.ll"; then
    echo "stable counted Slice loop kept its bounds branch" >&2
    exit 1
fi
grep -q 'beans_panic_slice_index' "$tmp/negative.ll"
grep -q 'beans_panic_slice_index' "$tmp/increment-first.ll"

echo "checking raw slice compile failures"
if ./build/beansc check test/cases/raw_slice_bad.b >"$tmp/bad" 2>&1; then
    echo "raw_slice_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q 'Slice.from_raw requires unsafe' "$tmp/bad"
grep -q 'Slice.set requires unsafe' "$tmp/bad"
grep -q 'Slice.subslice requires unsafe' "$tmp/bad"
grep -q 'looping over Slice requires unsafe' "$tmp/bad"
grep -q 'Slice indexing requires unsafe' "$tmp/bad"
grep -q 'Slice only supports inline scalars, RawPtr, fixed arrays, and extern "C" struct/union values' "$tmp/bad"

echo "ok two-word raw slices, checked access, subviews, iteration, and ABI"
