#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-unsafe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking raw pointer runtime parity"
./build/beansc run examples/unsafe_raw.b >"$tmp/interp"
./build/beansc build examples/unsafe_raw.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/unsafe_raw.out "$tmp/interp"
diff -u test/cases/unsafe_raw.out "$tmp/native.out"

set +e
./build/beansc run test/cases/unsafe_atomic_unaligned.b >"$tmp/align.interp" 2>&1
align_interp_status=$?
./build/beansc build test/cases/unsafe_atomic_unaligned.b -o "$tmp/align.native" \
    >"$tmp/align.build" 2>&1
align_build_status=$?
if [ "$align_build_status" -eq 0 ]; then
    "$tmp/align.native" >"$tmp/align.native.out" 2>&1
    align_native_status=$?
else
    align_native_status=0
fi
set -e
if [ "$align_interp_status" -eq 0 ] || [ "$align_build_status" -ne 0 ] || \
   [ "$align_native_status" -eq 0 ]; then
    echo "unaligned atomic access did not panic in both backends" >&2
    exit 1
fi
diff -u "$tmp/align.interp" "$tmp/align.native.out"
grep -q "unaligned raw pointer atomic access" "$tmp/align.interp"

echo "checking C ABI runtime parity"
./build/beansc run examples/ffi.b >"$tmp/ffi.interp"
./build/beansc build examples/ffi.b -o "$tmp/ffi.native" >"$tmp/ffi.build" 2>&1
"$tmp/ffi.native" >"$tmp/ffi.native.out"
diff -u test/cases/ffi.out "$tmp/ffi.interp"
diff -u test/cases/ffi.out "$tmp/ffi.native.out"

./build/beansc run test/cases/ffi_scalars.b >"$tmp/ffi-scalars.interp"
./build/beansc build test/cases/ffi_scalars.b \
    -o "$tmp/ffi-scalars.native" >"$tmp/ffi-scalars.build" 2>&1
"$tmp/ffi-scalars.native" >"$tmp/ffi-scalars.native.out"
diff -u test/cases/ffi_scalars.out "$tmp/ffi-scalars.interp"
diff -u test/cases/ffi_scalars.out "$tmp/ffi-scalars.native.out"

# Multi-argument externs with narrow (pointer or i32) parameters: the
# interpreter's word path can only pass those narrow in the final position,
# so on a 32-bit host these signatures must take the C ABI bridge with their
# declared widths. A regression here reads shifted argument slots and
# answers silently wrong rather than crashing.
./build/beansc run test/cases/ffi_words.b >"$tmp/ffi-words.interp"
./build/beansc build test/cases/ffi_words.b \
    -o "$tmp/ffi-words.native" >"$tmp/ffi-words.build" 2>&1
"$tmp/ffi-words.native" >"$tmp/ffi-words.native.out"
diff -u test/cases/ffi_words.out "$tmp/ffi-words.interp"
diff -u test/cases/ffi_words.out "$tmp/ffi-words.native.out"

# An aggregate signature is what forces both interpreters to compile a C
# bridge, and that helper has to come from the same driver selection as a
# build: BEANS_CC first, the platform clang otherwise. A literal "clang" in
# either interpreter would let an installation that names its compiler
# through BEANS_CC build programs and still fail the first FFI run.
echo "checking the interpreter C ABI bridge honors BEANS_CC"
./build/beansc run test/cases/ffi_aggregate.b >"$tmp/agg.interp"
./build/beansc0 run test/cases/ffi_aggregate.b >"$tmp/agg.interp0"
./build/beansc build test/cases/ffi_aggregate.b \
    -o "$tmp/agg.native" >"$tmp/agg.build" 2>&1
"$tmp/agg.native" >"$tmp/agg.native.out"
diff -u test/cases/ffi_aggregate.out "$tmp/agg.interp"
diff -u test/cases/ffi_aggregate.out "$tmp/agg.interp0"
diff -u test/cases/ffi_aggregate.out "$tmp/agg.native.out"
if BEANS_CC="$tmp/absent-cc" ./build/beansc run test/cases/ffi_aggregate.b \
    >"$tmp/agg.bad" 2>&1; then
    echo "beansc ignored BEANS_CC for the C ABI bridge" >&2
    exit 1
fi
grep -q "absent-cc could not build the C ABI bridge" "$tmp/agg.bad"
if BEANS_CC="$tmp/absent-cc" ./build/beansc0 run test/cases/ffi_aggregate.b \
    >"$tmp/agg0.bad" 2>&1; then
    echo "beansc0 ignored BEANS_CC for the C ABI bridge" >&2
    exit 1
fi
grep -q "absent-cc could not build the C ABI bridge" "$tmp/agg0.bad"

echo "checking unsafe compile failures and emitted IR"
if ./build/beansc check test/cases/unsafe_raw_bad.b >"$tmp/bad" 2>&1; then
    echo "unsafe_raw_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "RawPtr.read requires unsafe" "$tmp/bad"
grep -q "RawPtr.null requires unsafe" "$tmp/bad"
grep -q "RawPtr.alloc requires unsafe" "$tmp/bad"
grep -q "RawPtr.write requires unsafe" "$tmp/bad"
grep -q "RawPtr.read_volatile requires unsafe" "$tmp/bad"
grep -q "RawPtr.write_volatile requires unsafe" "$tmp/bad"
grep -q "RawPtr.atomic_load requires unsafe" "$tmp/bad"
grep -q "RawPtr.atomic_store requires unsafe" "$tmp/bad"
grep -q "RawPtr.atomic_fetch_add requires unsafe" "$tmp/bad"
grep -q "RawPtr.atomic_compare_exchange requires unsafe" "$tmp/bad"
grep -q "RawPtr.copy_from requires unsafe" "$tmp/bad"
grep -q "RawPtr.fill_zero requires unsafe" "$tmp/bad"
grep -q "RawPtr.element_size requires unsafe" "$tmp/bad"
grep -q "RawPtr.free requires unsafe" "$tmp/bad"
grep -q "Simd4f32.sum requires unsafe" "$tmp/bad"
grep -q "Simd4f32 arithmetic requires unsafe" "$tmp/bad"
grep -q "Simd4f32.splat requires unsafe" "$tmp/bad"
grep -q 'RawPtr only supports inline scalars, RawPtr, fixed arrays, and extern "C" struct/union values' "$tmp/bad"
grep -q "load volatile i1" build/unsafe_raw.ll
grep -q "store volatile i1" build/unsafe_raw.ll
grep -q "load atomic i64" build/unsafe_raw.ll
grep -q "store atomic i64" build/unsafe_raw.ll
grep -q "atomicrmw add" build/unsafe_raw.ll
grep -q "cmpxchg" build/unsafe_raw.ll

./build/beansc build examples/simd.b -o "$tmp/simd.native" >"$tmp/simd.build" 2>&1
./build/beansc run examples/simd.b >"$tmp/simd.interp"
"$tmp/simd.native" >"$tmp/simd.native.out"
diff -u "$tmp/simd.interp" "$tmp/simd.native.out"
grep -q "fadd <4 x float>" build/simd.ll
grep -q "fmul <4 x float>" build/simd.ll

if ./build/beansc check test/cases/ffi_bad.b >"$tmp/ffi.bad" 2>&1; then
    echo "ffi_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "extern C call 'llabs' requires unsafe" "$tmp/ffi.bad"
grep -q 'extern parameter needs an integer, float, bool, RawPtr, extern "C" struct/union, or C callback' "$tmp/ffi.bad"
grep -q 'extern return needs an integer, float, bool, RawPtr, extern "C" struct/union, or no value' "$tmp/ffi.bad"
grep -q "got Plain" "$tmp/ffi.bad"
grep -Fq "got fn(string) -> i32" "$tmp/ffi.bad"
grep -q "extern parameters cannot use move or inout" "$tmp/ffi.bad"
grep -q "extern functions cannot be generic" "$tmp/ffi.bad"
grep -q "extern function cannot use the reserved name 'main'" "$tmp/ffi.bad"
grep -q "cannot be stored as a Beans function value yet" "$tmp/ffi.bad"
grep -q "declare i64 @llabs(i64)" build/ffi.ll
grep -q "declare double @fabs(double)" build/ffi.ll
grep -q "declare float @fabsf(float)" build/ffi.ll
grep -q "declare double @ldexp(double, i32)" build/ffi.ll
grep -q "declare float @ldexpf(float, i32)" build/ffi.ll

echo "ok unsafe gate, raw memory, volatile/atomic access, SIMD, and C ABI calls"
