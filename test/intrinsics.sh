#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-intrinsics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking intrinsics in both backends"
./build/beansc run examples/intrinsics.b >"$tmp/interp"
./build/beansc build examples/intrinsics.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

echo "checking the results, including the edge cases the instructions have"
# The zero cases are the ones worth pinning: the instructions report the full width,
# so a software definition that looped or returned 63 would be wrong.
grep -q '^popcount 8 of zero 0$' "$tmp/interp"
grep -q '^leading zeros 63 of zero 64$' "$tmp/interp"
grep -q '^trailing zeros 3 of zero 64$' "$tmp/interp"
# The narrow byte swaps work on the low bytes and leave the rest zero.
grep -q '^bswap16 13330$' "$tmp/interp"       # 0x1234 -> 0x3412
grep -q '^bswap32 2018915346$' "$tmp/interp"  # 0x12345678 -> 0x78563412
grep -q '^bswap64 of one 72057594037927936$' "$tmp/interp"
grep -q '^rotate_left 2$' "$tmp/interp"
grep -q '^rotate_right 1$' "$tmp/interp"
grep -q '^rotate by zero 7$' "$tmp/interp"
grep -q '^sqrt 4 sqrt32 3$' "$tmp/interp"
grep -q '^fma 7 fma32 7$' "$tmp/interp"
grep -q '^hints are safe to ignore$' "$tmp/interp"

echo "checking the hardware CRC step matches the software one"
# This is the assertion that matters most in the file. The interpreter computes
# CRC32C in software; the native binary uses the machine's own instruction. They only
# agree if the polynomial, the byte order and the accumulator convention all match —
# and the first version here got the convention wrong, adding the pre/post inversion
# a *complete* CRC32C uses but the *instruction* does not.
#
# The feature has two names for one instruction — `crc` on arm64, `sse4.2` on x86-64 —
# and Beans has no conditional compilation, so the guard is written for the machine
# this is running on. That is also why the case lives here rather than in
# examples/intrinsics.b, which has to check on every architecture. The dotted x86 name
# is written with an underscore because `CpuFeature.sse4.2` is a field of a field.
case "$(uname -m)" in
    arm64|aarch64) crc_feature=crc ;;
    x86_64|amd64)  crc_feature=sse4_2 ;;
    *)             crc_feature="" ;;
esac
if [[ -z "$crc_feature" ]]; then
    echo "  (no CRC instruction is known for $(uname -m); the step was not compared)" >&2
else
cat >"$tmp/crc.b" <<CRC
import std.io
import std.cpu
import std.intrinsic
fn main() {
    unsafe {
        if cpu.has(CpuFeature.$crc_feature) {
            var acc: int = 0
            var i: int = 0
            for i < 8 {
                acc = intrinsic.crc32c(acc, i * 2654435761)
                i += 1
            }
            io.println("crc {acc}")
        } else {
            io.println("crc unavailable")
        }
    }
}
CRC
./build/beansc run "$tmp/crc.b" >"$tmp/crc.interp"
./build/beansc build "$tmp/crc.b" -o "$tmp/crc" >/dev/null 2>&1
"$tmp/crc" >"$tmp/crc.native"
diff -u "$tmp/crc.interp" "$tmp/crc.native"
if grep -q '^crc unavailable$' "$tmp/crc.interp"; then
    echo "note: this machine has no CRC instruction; the step was not compared" >&2
else
    # Eight chained steps, so a wrong convention cannot cancel out.
    grep -qE '^crc [0-9]+$' "$tmp/crc.interp"
fi
# The guarded call must land in its own function carrying the target feature. Inline it
# would be "Cannot select" on any target whose baseline lacks the instruction.
./build/beansc build "$tmp/crc.b" --emit ir >/dev/null
grep -q "\"target-features\"=\"+" build/crc.ll || {
    echo "the feature-gated intrinsic was emitted without a target-features function" >&2
    exit 1
}
grep -q 'call i64 @beans_feat_crc32c' build/crc.ll
fi

echo "checking the emitted calls are real LLVM intrinsics"
./build/beansc build examples/intrinsics.b --emit ir >/dev/null
grep -q 'call i64 @llvm.ctpop.i64' build/intrinsics.ll
# ctlz/cttz take an is-zero-undefined flag, and it must be false: zero is defined.
grep -q 'call i64 @llvm.ctlz.i64(i64 .*, i1 false)' build/intrinsics.ll
grep -q 'call i64 @llvm.cttz.i64(i64 .*, i1 false)' build/intrinsics.ll
# A narrow swap is trunc, the narrow intrinsic, then zext.
grep -q 'call i16 @llvm.bswap.i16' build/intrinsics.ll
grep -q 'call i32 @llvm.bswap.i32' build/intrinsics.ll
grep -q 'call i64 @llvm.bswap.i64' build/intrinsics.ll
# A rotate is a funnel shift with both halves the same register.
grep -qE 'call i64 @llvm.fshl.i64\(i64 (%t[0-9]+|[0-9]+), i64 \1,' build/intrinsics.ll
grep -q 'call double @llvm.sqrt.f64' build/intrinsics.ll
grep -q 'call float @llvm.sqrt.f32' build/intrinsics.ll
grep -q 'call double @llvm.fma.f64' build/intrinsics.ll
grep -q 'call float @llvm.fma.f32' build/intrinsics.ll
grep -q 'call void @llvm.prefetch.p0' build/intrinsics.ll
# spin_hint has no portable intrinsic, so it is a runtime call by design.
grep -q 'call void @beans_spin_hint()' build/intrinsics.ll
# fma must not have been turned into a multiply and an add — that would round twice.
if grep -qE 'fmul double .*\n.*fadd double' build/intrinsics.ll; then
    echo "fma was lowered to a multiply and an add" >&2
    exit 1
fi

echo "checking the arch-specific spelling follows the target"
# One name, two instructions. x86's CRC32 is all 64-bit; arm64's CRC32C takes and
# returns a 32-bit accumulator, so the operand is narrowed and widened around it.
./build/beansc build --target x86_64-unknown-linux-gnu --features +sse4.2 --emit ir \
    test/cases/intrinsic_unguarded.b >/dev/null
grep -q 'call i64 @llvm.x86.sse42.crc32.64.64' build/intrinsic_unguarded.ll
./build/beansc build --target aarch64-unknown-linux-gnu --features +crc --emit ir \
    test/cases/intrinsic_unguarded.b >/dev/null
grep -q 'call i32 @llvm.aarch64.crc32cx' build/intrinsic_unguarded.ll

echo "checking the allowlist is closed"
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
expect_error "no intrinsic 'vpternlogd'" test/cases/intrinsic_unknown.b
expect_error "requires unsafe { }" test/cases/intrinsic_unsafe.b
expect_error "argument 1 is float, got string" test/cases/intrinsic_wrong_type.b
expect_error "takes 3 arguments but got 2" test/cases/intrinsic_arity.b
expect_error "so the call has to be guarded" test/cases/intrinsic_unguarded.b

echo "ok intrinsics: exact signatures, the instructions' own edge cases, and the guard"
