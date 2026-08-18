#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-simd.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking SIMD families in both backends"
./build/beansc run examples/simd_families.b >"$tmp/interp"
./build/beansc build examples/simd_families.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

# The old single-type example must still behave exactly as it did: Simd4f32 is no
# longer special-cased anywhere, so this is the regression guard for the rewrite.
./build/beansc run examples/simd.b >"$tmp/legacy.interp"
./build/beansc build examples/simd.b -o "$tmp/legacy" >/dev/null 2>&1
"$tmp/legacy" >"$tmp/legacy.native"
diff -u "$tmp/legacy.interp" "$tmp/legacy.native"
grep -q '^simd 3 6 9 12 sum 30$' "$tmp/legacy.interp"

echo "checking the results themselves"
grep -q '^shape 4 lanes$' "$tmp/interp"
grep -q '^sum 10 product 24$' "$tmp/interp"
# A mask lane is all-ones or all-zeros; select must pick per lane, so the first two
# lanes come from the second argument and the last two from the first.
grep -q '^select 1 2 10 10$' "$tmp/interp"
grep -q '^mask any true all false$' "$tmp/interp"
# Unsigned lanes wrap and compare unsigned: 200 + 100 is 44, and 200 > 100.
grep -q '^u8 wrap 44$' "$tmp/interp"
grep -q '^u8 unsigned compare true$' "$tmp/interp"
# A signed narrow shift carries the sign bit down: -8 >> 2 is -2, not a big
# positive number.
grep -q '^i16 -8 shr -2 sum -64$' "$tmp/interp"
# The same method on an unsigned family shifts in zeros instead: 200 >> 1 is 100.
grep -q '^u8 shr 100$' "$tmp/interp"
# with_lane copies; the original is untouched.
grep -q '^with_lane 99 original 2$' "$tmp/interp"
grep -q '^equal true false$' "$tmp/interp"
grep -q '^roundtrip 3$' "$tmp/interp"
grep -q '^unaligned roundtrip 2$' "$tmp/interp"

echo "checking the emitted vector instructions"
./build/beansc build examples/simd_families.b --emit ir >/dev/null
# Every family is a real LLVM vector type, not a struct or an array.
grep -q '<4 x i32>' build/simd_families.ll
grep -q '<16 x i8>' build/simd_families.ll
grep -q '<8 x i16>' build/simd_families.ll
grep -q '<2 x double>' build/simd_families.ll
grep -q '<4 x float>' build/simd_families.ll
# Lane-wise arithmetic is one instruction, not a loop.
grep -q 'add <4 x i32>' build/simd_families.ll
grep -q 'fmul <2 x double>' build/simd_families.ll
# Unsigned lanes must use the unsigned opcodes, signed the signed ones.
grep -q 'icmp ugt <16 x i8>' build/simd_families.ll
grep -q 'ashr <8 x i16>' build/simd_families.ll
grep -q 'lshr <16 x i8>' build/simd_families.ll
# A comparison mask is sext of the i1 lanes, which is what select reads as bits.
grep -q 'sext <4 x i1> .* to <4 x i32>' build/simd_families.ll
# Float masks and float bitwise choices go through the integer view: LLVM has no
# `and` or `xor` on a float vector.
grep -q 'bitcast <4 x float> .* to <4 x i32>' build/simd_families.ll
# splat is insertelement plus a zero shuffle, whatever the lane count.
grep -q 'shufflevector <16 x i8> .* zeroinitializer' build/simd_families.ll
# An aligned store states the vector's width; the unaligned form states 1.
grep -q 'store <4 x i32> .*, align 16' build/simd_families.ll
grep -q 'store <4 x i32> .*, align 1$' build/simd_families.ll
if grep -qE '(load|store) atomic <' build/simd_families.ll; then
    echo "a vector atomic was emitted" >&2
    exit 1
fi

echo "checking 256-bit follows the selected features"
# Simd8i32 is 256 bits. x86-64 with +avx2 has the registers; plain x86-64 does not,
# and neither does arm64. The rejection names the target, so a cross build cannot
# silently produce a vector the machine will split.
./build/beansc build --target x86_64-unknown-linux-gnu --features +avx2 --emit ir \
    test/cases/simd_bad_width.b >/dev/null
grep -q '<8 x i32>' build/simd_bad_width.ll
if ./build/beansc build --target x86_64-unknown-linux-gnu --emit ir \
    test/cases/simd_bad_width.b >"$tmp/no_avx" 2>&1; then
    echo "Simd8i32 compiled for plain x86-64, which has no 256-bit registers" >&2
    exit 1
fi
grep -qF "supports at most 128" "$tmp/no_avx"

echo "checking lane and shift bounds panic identically"
for case in simd_lane_oob simd_shift_oob; do
    set +e
    ./build/beansc run "test/cases/$case.b" >"$tmp/$case.interp" 2>&1
    interp_status=$?
    ./build/beansc build "test/cases/$case.b" -o "$tmp/$case.native" \
        >"$tmp/$case.build" 2>&1
    build_status=$?
    if [[ "$build_status" -eq 0 ]]; then
        "$tmp/$case.native" >"$tmp/$case.native.out" 2>&1
        native_status=$?
    else
        native_status=0
    fi
    set -e
    if [[ "$interp_status" -eq 0 || "$build_status" -ne 0 || "$native_status" -eq 0 ]]; then
        echo "$case did not panic in both backends" >&2
        exit 1
    fi
    diff -u "$tmp/$case.interp" "$tmp/$case.native.out"
done
grep -q 'SIMD lane out of range (lanes 4)' "$tmp/simd_lane_oob.interp"
grep -q 'SIMD shift outside 0..31' "$tmp/simd_shift_oob.interp"

echo "checking invalid shapes and operations are rejected"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
expect_error "supports at most 128" test/cases/simd_bad_width.b
expect_error "unknown type 'Simd3i32'" test/cases/simd_bad_name.b
expect_error "Simd4f32 has no method 'bit_and'" test/cases/simd_bad_float_bits.b
expect_error "requires unsafe { }" test/cases/simd_bad_unsafe.b
expect_error "'Simd4i32.of' takes 4 arguments but got 2" test/cases/simd_bad_arity.b

echo "ok SIMD families: every shape, mask, reduction, and rejection"
