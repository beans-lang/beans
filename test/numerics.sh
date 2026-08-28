#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-numeric.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/numeric_ok.b >"$tmp/interp"
./build/beansc build test/cases/numeric_ok.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/numeric_ok.out "$tmp/interp"
diff -u test/cases/numeric_ok.out "$tmp/native.out"

./build/beansc run test/cases/float_surface.b >"$tmp/surface.interp"
./build/beansc build test/cases/float_surface.b \
    -o "$tmp/surface.native" >"$tmp/surface.build" 2>&1
"$tmp/surface.native" >"$tmp/surface.native.out"
diff -u test/cases/float_surface.out "$tmp/surface.interp"
diff -u test/cases/float_surface.out "$tmp/surface.native.out"

./build/beansc run test/cases/decimal_rounding.b >"$tmp/round.interp"
./build/beansc build test/cases/decimal_rounding.b \
    -o "$tmp/round.native" >"$tmp/round.build" 2>&1
"$tmp/round.native" >"$tmp/round.native.out"
diff -u test/cases/decimal_rounding.out "$tmp/round.interp"
diff -u test/cases/decimal_rounding.out "$tmp/round.native.out"
if ./build/beansc check test/cases/decimal_rounding_bad.b \
    >"$tmp/round.bad" 2>&1; then
    echo "unknown decimal rounding mode passed checking" >&2
    exit 1
fi
grep -q "unknown rounding mode 'sideways'" "$tmp/round.bad"

# Scale is part of the answer. A zero operand used to hand back the other side
# untouched, so 0.00 + 233 lost its cents, and a compound assignment to a
# decimal field was refused by the native backend alone — the checker and the
# interpreter both took it, so a program that ran would not build.
./build/beansc run test/cases/decimal_scale.b >"$tmp/scale.interp"
./build/beansc build test/cases/decimal_scale.b \
    -o "$tmp/scale.native" >"$tmp/scale.build" 2>&1
"$tmp/scale.native" >"$tmp/scale.native.out"
diff -u test/cases/decimal_scale.out "$tmp/scale.interp"
diff -u test/cases/decimal_scale.out "$tmp/scale.native.out"
grep -q 'call void @beans_decv_add(' build/decimal_scale.ll

./build/beansc run test/cases/decimal_precision.b >"$tmp/precision.interp"
./build/beansc build test/cases/decimal_precision.b \
    -o "$tmp/precision.native" >"$tmp/precision.build" 2>&1
"$tmp/precision.native" >"$tmp/precision.native.out"
diff -u test/cases/decimal_precision.out "$tmp/precision.interp"
diff -u test/cases/decimal_precision.out "$tmp/precision.native.out"

./build/beansc run test/cases/decimal_extrema.b >"$tmp/extrema.interp"
./build/beansc build test/cases/decimal_extrema.b \
    -o "$tmp/extrema.native" >"$tmp/extrema.build" 2>&1
"$tmp/extrema.native" >"$tmp/extrema.native.out"
diff -u test/cases/decimal_extrema.out "$tmp/extrema.interp"
diff -u test/cases/decimal_extrema.out "$tmp/extrema.native.out"
if ./build/beansc check test/cases/decimal_precision_bad.b \
    >"$tmp/precision.bad" 2>&1; then
    echo "39-digit decimal literal passed checking" >&2
    exit 1
fi
grep -q "decimal literal exceeds 38-digit precision or scale" \
    "$tmp/precision.bad"

for name in decimal_overflow_add decimal_overflow_compound decimal_overflow_mul; do
    ./build/beansc build "test/cases/$name.b" \
        -o "$tmp/$name.native" >"$tmp/$name.build" 2>&1
    set +e
    ./build/beansc run "test/cases/$name.b" \
        >"$tmp/$name.interp" 2>&1
    interp_status=$?
    "$tmp/$name.native" >"$tmp/$name.native.out" 2>&1
    native_status=$?
    set -e
    test "$interp_status" -eq 3
    test "$native_status" -eq 3
    diff -u "$tmp/$name.interp" "$tmp/$name.native.out"
    grep -q "decimal overflow" "$tmp/$name.interp"
done

# Decimal is a real wide value in normal native code. The one-slot generic
# runtime boxes it only at a remaining one-slot key or enum boundary.
grep -q '^; main.add_cent$' build/numeric_ok.ll
grep -q '^define { i128, i64, i64 } @.next.fn[0-9]*(i128 %arg[0-9]*[.]coeff, i64 %arg[0-9]*[.]scale)' \
    build/numeric_ok.ll
# Internal calls flatten decimal arguments. This class initializer puts a
# decimal after pointer and byte arguments, the shape that s390x used to copy
# into one overwritten stack slot.
grep -q '^define void @.next.fn[0-9]*(ptr %arg0, i8 %arg1, i128 %arg2[.]coeff, i64 %arg2[.]scale, i8 %arg3)' \
    build/numeric_ok.ll
if grep -Eq '^define .*\(.*\{ ?i128, i64, i64 ?\} %arg' build/numeric_ok.ll; then
    echo "decimal aggregate leaked into the internal function ABI" >&2
    exit 1
fi
grep -Eq 'store \{ ?i128, i64, i64 ?\}' build/numeric_ok.ll
grep -q 'call ptr @beans_decv_box(ptr' build/numeric_ok.ll
# Fixed-scale compound updates stay inline after widening decimal from the old
# packed form. These constants catch an accidental helper-only fallback.
grep -Eq 'add i128 %t[0-9]+, 125' build/numeric_ok.ll
grep -Eq 'add i128 %t[0-9]+, -50' build/numeric_ok.ll

if ./build/beansc check test/cases/numeric_bad.b >"$tmp/bad" 2>&1; then
    echo "numeric_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "128 does not fit i8 (-128..127)" "$tmp/bad"
grep -q -- "-129 does not fit i8 (-128..127)" "$tmp/bad"
grep -q -- "-1 does not fit u8 (0..255)" "$tmp/bad"
grep -q "256 does not fit u8 (0..255)" "$tmp/bad"
grep -q "2147483648 does not fit i32 (-2147483648..2147483647)" "$tmp/bad"
grep -q "18446744073709551616 does not fit u64 (0..18446744073709551615)" "$tmp/bad"
grep -q "32768 does not fit i16 (-32768..32767)" "$tmp/bad"
grep -q -- "-32769 does not fit i16 (-32768..32767)" "$tmp/bad"
grep -q "65536 does not fit u16 (0..65535)" "$tmp/bad"
grep -q -- "-2147483649 does not fit i32 (-2147483648..2147483647)" "$tmp/bad"
grep -q "4294967296 does not fit u32 (0..4294967295)" "$tmp/bad"
grep -q "9223372036854775808 does not fit int (-9223372036854775808..9223372036854775807)" "$tmp/bad"
grep -q -- "-9223372036854775809 does not fit int (-9223372036854775808..9223372036854775807)" "$tmp/bad"
grep -q -- "-1 does not fit u64 (0..18446744073709551615)" "$tmp/bad"


# A number literal written straight under `as` is read in the target type. It
# used to become an f64 first, so `19.99 as decimal` carried the float's error
# in the one type that exists to have none — and a hex literal in a float or a
# decimal was taken by the checker and then read two different ways by the two
# backends.
./build/beansc run test/cases/numeric_cast_literal.b >"$tmp/castlit.interp"
./build/beansc build test/cases/numeric_cast_literal.b \
    -o "$tmp/castlit.native" >"$tmp/castlit.build" 2>&1
"$tmp/castlit.native" >"$tmp/castlit.native.out"
diff -u test/cases/numeric_cast_literal.out "$tmp/castlit.interp"
diff -u test/cases/numeric_cast_literal.out "$tmp/castlit.native.out"
if ./build/beansc check test/cases/numeric_cast_literal_bad.b \
    >"$tmp/castlit.bad" 2>&1; then
    echo "a 64-bit-wide hex literal passed checking in a float" >&2
    exit 1
fi
grep -q "hex or binary literal 0xFFFFFFFFFFFFFFFF does not fit float" \
    "$tmp/castlit.bad"

# The scale of a zero, of a sum whose operands are far apart, and of a zero
# quotient. Answers cross-checked against Python's decimal module at 38 digits
# half-even; test/decimal_conformance.sh replays the IBM operand suite against
# the same oracle.
./build/beansc run test/cases/decimal_zero_scale.b >"$tmp/zscale.interp"
./build/beansc build test/cases/decimal_zero_scale.b \
    -o "$tmp/zscale.native" >"$tmp/zscale.build" 2>&1
"$tmp/zscale.native" >"$tmp/zscale.native.out"
diff -u test/cases/decimal_zero_scale.out "$tmp/zscale.interp"
diff -u test/cases/decimal_zero_scale.out "$tmp/zscale.native.out"

# A float-to-int cast saturates at the target type's own range, NaN to zero,
# every width from f32 and f64. The native backend emitted a bare fptosi, which
# LLVM defines as poison there, so the answer moved with the optimizer.
./build/beansc run test/cases/float_int_cast.b >"$tmp/fcast.interp"
./build/beansc build test/cases/float_int_cast.b \
    -o "$tmp/fcast.native" >"$tmp/fcast.build" 2>&1
"$tmp/fcast.native" >"$tmp/fcast.native.out"
diff -u test/cases/float_int_cast.out "$tmp/fcast.interp"
diff -u test/cases/float_int_cast.out "$tmp/fcast.native.out"
# ...and it is the intrinsic doing it, not the instruction set being kind: a
# bare fptosi/fptoui must not appear at all.
for width in i8 i16 i32 i64; do
    grep -q "call $width @llvm.fptosi.sat.$width.f64(" build/float_int_cast.ll
    grep -q "call $width @llvm.fptoui.sat.$width.f64(" build/float_int_cast.ll
    grep -q "call $width @llvm.fptosi.sat.$width.f32(" build/float_int_cast.ll
done
if grep -Eq '= (fptosi|fptoui) ' build/float_int_cast.ll; then
    echo "a bare fptosi/fptoui survived in float_int_cast.ll" >&2
    grep -nE '= (fptosi|fptoui) ' build/float_int_cast.ll >&2
    exit 1
fi

echo "ok numeric widths, boundaries, unsigned operations, f32, and checked 38-digit decimal"
echo "   plus literal casts, decimal result scales, and saturating float-to-int"
