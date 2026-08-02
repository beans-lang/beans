#!/usr/bin/env bash
# Make a host Clang stand in for a target-native Clang in qemu-user hosted
# gates. Real machines do not use this wrapper.
set -euo pipefail

: "${BEANS_CLANG_TARGET:?BEANS_CLANG_TARGET is required}"
: "${BEANS_CLANG_SYSROOT:?BEANS_CLANG_SYSROOT is required}"

args=(
    --target="$BEANS_CLANG_TARGET"
    --sysroot="$BEANS_CLANG_SYSROOT"
)

# Clang otherwise auto-detects a same-architecture GNU cross compiler installed
# on the runner. Its glibc headers can then win over a musl sysroot even though
# --sysroot is correct. Point it at the toolchain that owns the sysroot.
if [[ -n "${BEANS_CLANG_GCC_TOOLCHAIN:-}" ]]; then
    args+=(--gcc-toolchain="$BEANS_CLANG_GCC_TOOLCHAIN")
fi

exec "${BEANS_CLANG:-clang}" "${args[@]}" "$@"
