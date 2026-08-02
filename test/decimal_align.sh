#!/usr/bin/env bash
# Decimal stack slots must state `align 16`, asserted on emitted IR.
#
# A `decimal` is `{i128, i64, i64}`, ABI-sized to 32 and aligned to 16.
# The explicit tail makes the LLVM value the same size as the C runtime's BDec;
# without it, LLVM can make the value 24 bytes on POWER and a runtime out-write
# can overlap the next stack slot. The compiler also emits textual IR
# with a `target triple` but no `target datalayout`, so LLVM aligns `i128` from
# the triple's default — and the powerpc64le default drops `i128:128`, which
# leaves an `alloca {i128, i64, i64}` at `align 8`. The C runtime, compiled through
# Clang's own frontend, accesses a `decimal` as 16-aligned; a stack slot handed
# to it at 8 was read half-off on ppc64le, silently zeroing the i128 coefficient
# while the i64 scale survived (`20.00` came back `0.00`). x86-64 and riscv64
# tolerate the under-alignment, so only POWER surfaced it — which is exactly why
# this guard reads the IR instead of trusting a run on the host.
#
# The rule: every `alloca` of the decimal aggregate carries `, align 16`, and no
# bare (unaligned) decimal alloca is emitted — by both compilers, on every
# decimal-capable target. `--emit ir` needs no sysroot, so this runs on the host.
set -uo pipefail

cd "$(dirname "$0")/.."
src="examples/wide_lists.b"   # exercises List<decimal> plus decimal temporaries
tmp="${TMPDIR:-/tmp}/beans-decimal-align.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

compilers=()
[ -x build/beansc0 ] && compilers+=("build/beansc0")
[ -x build/beansc ] && compilers+=("build/beansc")
if [ "${#compilers[@]}" -eq 0 ]; then
    echo "decimal_align: no compiler built (need build/beansc0 or build/beansc)" >&2
    exit 1
fi

# Decimal-capable targets. ppc64le is the one whose
# triple-default datalayout drops i128:128, so it is the point of the test; the
# others prove the stated alignment is a no-op where LLVM already agrees.
targets=(
    ""
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "riscv64-unknown-linux-gnu"
    "powerpc64le-unknown-linux-gnu"
    "arm-unknown-linux-gnueabi"
    "arm-unknown-linux-gnueabihf"
    "loongarch64-unknown-linux-gnu"
    "loongarch64-unknown-linux-musl"
    "powerpc-unknown-linux-gnu"
    "powerpc64-unknown-linux-gnu"
    "powerpc64-unknown-linux-musl"
    "s390x-unknown-linux-gnu"
)

# Matches the decimal aggregate as either compiler spells it.
dec_alloca='alloca \{ ?i128, i64, i64 ?\}'

fail=0
checked=0
for compiler in "${compilers[@]}"; do
    for target in "${targets[@]}"; do
        label="${target:-host}"
        ll="$tmp/$(basename "$compiler").${label}.ll"
        args=(build --emit ir "$src" -o "$ll")
        [ -n "$target" ] && args=(build --target "$target" --emit ir "$src" -o "$ll")
        if ! "./$compiler" "${args[@]}" >"$tmp/build.log" 2>&1; then
            echo "FAIL: $compiler could not emit IR for $label"
            cat "$tmp/build.log"
            fail=1
            continue
        fi
        checked=$((checked + 1))

        total=$(grep -cE "$dec_alloca" "$ll")
        if [ "$total" -eq 0 ]; then
            echo "FAIL ($compiler/$label): no decimal alloca in IR — test source stopped exercising decimals?"
            fail=1
            continue
        fi
        # (1) no bare decimal alloca — the aggregate at end of line, no `, align`
        if grep -nE "$dec_alloca\$" "$ll" >"$tmp/bare" 2>/dev/null; then
            echo "FAIL ($compiler/$label): decimal alloca without align 16:"
            head -3 "$tmp/bare"
            fail=1
        fi
        # (2) every decimal alloca states align 16
        aligned=$(grep -cE "$dec_alloca, align 16" "$ll")
        if [ "$aligned" -ne "$total" ]; then
            echo "FAIL ($compiler/$label): $aligned of $total decimal allocas are align 16"
            fail=1
        fi
        # (3) closure calls use the scalar-parts internal ABI. These two thunks
        # caught the last s390x aggregate callers: sort_by takes two decimals,
        # and sort_by_key takes one.
        if ! grep -q 'call i1 %fp(ptr %box, i128 %ta.coeff, i64 %ta.scale, i128 %tb.coeff, i64 %tb.scale)' "$ll" ||
           ! grep -q 'call i64 %fp(ptr %box, i128 %ta.coeff, i64 %ta.scale)' "$ll"; then
            echo "FAIL ($compiler/$label): decimal sort thunk did not flatten its arguments"
            fail=1
        fi
        if grep -Eq 'call i(1|64) %fp\(ptr %box, \{ ?i128, i64, i64 ?\}' "$ll"; then
            echo "FAIL ($compiler/$label): decimal aggregate leaked into a closure call"
            fail=1
        fi
    done
done

if [ "$fail" != "0" ]; then
    echo "decimal_align: FAIL"
    exit 1
fi
echo "ok decimal_align: ${checked} (compiler x target) IR emissions, every decimal"
echo "   stack slot is 32 bytes and align 16; closure arguments are scalar parts"
