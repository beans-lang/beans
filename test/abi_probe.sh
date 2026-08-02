#!/usr/bin/env bash
# Clang ABI probe — the evidence behind the portable fallible-builtin boundary.
#
# For every target Beans compiles for, this shows two things about the C runtime's
# fallible-return shapes (test/fixtures/abi_probe.c):
#
#   1. The native aggregate ABI DIFFERS by target. Returning a 16-byte {i64, ptr}
#      by value is an sret pointer on some targets (Win64, i686, ARMv7, s390x) and
#      a register pair on others (SysV x86-64, AAPCS64 incl. ARM64 *Windows*,
#      RISC-V64, PPC64LE). Hard-coding that from the object format is the bug this
#      work removes — it wrongly grouped ARM64 Windows with x86-64 Windows.
#
#   2. The `_out` wrapper ABI is scalar plus a pointer EVERYWHERE: `define i64
#      @probe_*_out(..., ptr)`, no sret, on every target. That is why generated
#      code can call it with one shape and never ask the object format anything.
#
# A local clang without a backend for a triple SKIPs with a message. In CI
# (BEANS_REQUIRE_ALL_TARGETS=1) a missing backend is a failure, not a quiet pass.
set -uo pipefail

cd "$(dirname "$0")/.."
cc="${BEANS_PROBE_CC:-${CC:-clang}}"
fixture="test/fixtures/abi_probe.c"
require_all="${BEANS_REQUIRE_ALL_TARGETS:-0}"
tmp="${TMPDIR:-/tmp}/beans-abi-probe.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# The registered triples the boundary has to be correct for, with the native aggregate
# return each one uses — recorded so the probe's finding can be checked against
# the documented ABI, not just printed.
targets=(
    "x86_64-unknown-linux-gnu:register-pair"
    "aarch64-unknown-linux-gnu:register-pair"
    "x86_64-pc-windows-gnu:sret"
    "aarch64-pc-windows-gnu:register-pair"
    "i686-pc-windows-gnu:sret"
    "i686-unknown-linux-gnu:sret"
    "armv7-unknown-linux-gnueabihf:sret"
    "arm-unknown-linux-gnueabi:sret"
    "arm-unknown-linux-gnueabihf:sret"
    "riscv64-unknown-linux-gnu:register-pair"
    "loongarch64-unknown-linux-gnu:register-pair"
    "powerpc64le-unknown-linux-gnu:register-pair"
    "powerpc-unknown-linux-gnu:sret"
    "powerpc64-unknown-linux-gnu:sret"
    "powerpc64-unknown-linux-musl:register-pair"
    "s390x-unknown-linux-gnu:sret"
)

printf '%-32s  %-18s  %-10s  %s\n' "target" "native BRes ret" "expected" "_out wrapper"
printf '%-32s  %-18s  %-10s  %s\n' "------" "---------------" "--------" "------------"

fail=0
skipped=0
ran=0
for entry in "${targets[@]}"; do
    triple="${entry%%:*}"
    expected="${entry##*:}"
    ir="$tmp/${triple}.ll"
    if ! "$cc" --target="$triple" -O2 -S -emit-llvm "$fixture" -o "$ir" \
            >"$tmp/${triple}.cc.log" 2>&1; then
        if [ "$require_all" = "1" ]; then
            printf '%-32s  %s\n' "$triple" "FAIL: clang cannot target this triple"
            fail=1
        else
            printf '%-32s  %s\n' "$triple" "skip (no backend in $(basename "$cc"))"
            skipped=$((skipped + 1))
        fi
        continue
    fi
    ran=$((ran + 1))

    # How did clang return the by-value aggregate? sret when the define takes a
    # hidden `sret` first parameter; a register/direct return otherwise.
    if grep -Eq '^define[^@]*@probe_bres\(ptr[^)]*sret' "$ir"; then
        native="sret"
    else
        native="register-pair"
    fi

    # The wrapper must be scalar on every target: i64 return, no sret parameter.
    out_ok="yes"
    for fn in probe_bres_out probe_bopt_out; do
        line=$(grep -E "^define[^@]*@${fn}\(" "$ir" || true)
        if ! printf '%s' "$line" | grep -Eq '^define[^@]*i64 @'; then
            out_ok="no (return not i64)"
            fail=1
        elif printf '%s' "$line" | grep -q 'sret'; then
            out_ok="no (has sret)"
            fail=1
        fi
    done

    note=""
    if [ "$native" != "$expected" ]; then
        note="  <-- native differs from documented ($expected)"
        # Not fatal by itself: a clang version may classify differently. The hard
        # assertion is on the wrapper. But surface it loudly.
    fi
    printf '%-32s  %-18s  %-10s  %s%s\n' \
        "$triple" "$native" "$expected" "$out_ok" "$note"
done

echo
echo "ran=$ran skipped=$skipped"
if [ "$ran" = "0" ]; then
    echo "abi_probe: nothing compiled — clang has no usable backend here"
    [ "$require_all" = "1" ] && exit 1
    echo "abi_probe: skipped (set BEANS_REQUIRE_ALL_TARGETS=1 in CI to require all)"
    exit 0
fi
if [ "$fail" != "0" ]; then
    echo "abi_probe: FAIL — a wrapper was not scalar, or a required target was missing"
    exit 1
fi
echo "ok abi_probe: native aggregate return varies by target; the _out wrapper is"
echo "   scalar (i64 value + output pointer) on every target that compiled"
