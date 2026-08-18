#!/usr/bin/env bash
# The portable fallible-builtin ABI, asserted on emitted IR.
#
# Generated code must call the runtime's fallible/optional builtins through the
# scalar `<sym>_out` wrappers — value returned normally, error/presence word
# through an output pointer — and must never take a BRes/BOpt struct back across
# the C boundary. This test fails if either compiler reintroduces an aggregate
# return or an sret call for a runtime builtin, on any target.
#
# It runs both compilers over a spread of targets, including the two whose native
# aggregate ABI disagree with each other — x86_64 Windows (sret) and aarch64
# Windows (register pair) — because encoding that difference is the bug this ABI
# removes. `--emit ir` needs no sysroot, so every target is checkable here.
#
# The ban is scoped to the runtime's own `@beans_` symbols. User `extern "C"`
# aggregate calls legitimately use sret and are Clang's job; the probe program has
# no `extern "C"` so the runtime boundary is tested in isolation.
set -uo pipefail

cd "$(dirname "$0")/.."
src="test/cases/runtime_abi_probe.b"
tmp="${TMPDIR:-/tmp}/beans-runtime-abi.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

compilers=()
[ -x build/beansc ] && compilers+=("build/beansc")
if [ "${#compilers[@]}" -eq 0 ]; then
    echo "runtime_abi: no compiler built (need build/beansc)" >&2
    exit 1
fi

# host build plus the cross targets the boundary has to be identical on. The two
# Windows entries are the point: same scalar IR despite opposite native ABIs.
targets=(
    ""
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "x86_64-pc-windows-gnu"
    "aarch64-pc-windows-gnullvm"
    "i686-pc-windows-gnu"
    "riscv64-unknown-linux-gnu"
    "i686-unknown-linux-gnu"
    "armv7-unknown-linux-gnueabihf"
    "arm-unknown-linux-gnueabi"
    "arm-unknown-linux-gnueabihf"
    "powerpc64le-unknown-linux-gnu"
    "loongarch64-unknown-linux-gnu"
    "loongarch64-unknown-linux-musl"
    "powerpc-unknown-linux-gnu"
    "powerpc64-unknown-linux-gnu"
    "powerpc64-unknown-linux-musl"
    "s390x-unknown-linux-gnu"
)

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

        # (1) no aggregate return from a runtime builtin call
        if grep -nE '= call \{[^}]*\} @beans_' "$ll" >"$tmp/hit" 2>/dev/null; then
            echo "FAIL ($compiler/$label): aggregate return from a runtime call:"
            cat "$tmp/hit"
            fail=1
        fi
        # (2) no aggregate-return or sret declaration of a runtime builtin
        if grep -nE '^declare \{[^}]*\} @beans_|^declare void @beans_[a-z_0-9]+\(ptr sret' \
                "$ll" >"$tmp/hit" 2>/dev/null; then
            echo "FAIL ($compiler/$label): aggregate/sret declaration of a runtime builtin:"
            cat "$tmp/hit"
            fail=1
        fi
        # (3) no sret anywhere touching a runtime symbol (this program has no
        #     extern "C", so any sret at all is a runtime-boundary regression)
        if grep -nE 'sret' "$ll" >"$tmp/hit" 2>/dev/null; then
            echo "FAIL ($compiler/$label): sret in a program with no extern \"C\":"
            cat "$tmp/hit"
            fail=1
        fi
        # (4) the scalar wrappers are actually the form used
        for want in beans_str_to_int_out beans_str_find_out beans_map_get_raw_out; do
            if ! grep -qE "call i64 @${want}\(" "$ll"; then
                echo "FAIL ($compiler/$label): expected scalar call @${want} not found"
                fail=1
            fi
        done
    done
done

if [ "$fail" != "0" ]; then
    echo "runtime_abi: FAIL"
    exit 1
fi
echo "ok runtime_abi: ${checked} (compiler x target) IR emissions, all scalar"
echo "   value + output-pointer calls; no BRes/BOpt aggregate or sret on any"
echo "   runtime builtin, x86_64 and aarch64 Windows included"
