#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-stage0-windows.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

require=${BEANS_WINDOWS_REQUIRE:-0}
skip_or_fail() {
    if [[ "$require" == 1 ]]; then
        echo "windows_stage0: FAIL — $1" >&2
        exit 1
    fi
    echo "windows_stage0: skip — $1"
    exit 0
}

command -v clang++ >/dev/null || skip_or_fail "no clang++"
command -v wine >/dev/null || skip_or_fail "no wine"
[[ -d /usr/x86_64-w64-mingw32 ]] || skip_or_fail "no x86-64 MinGW sysroot"

echo "checking the C++ stage 0 builds and runs as a native Windows program"
make --no-print-directory OS=Windows_NT CXX=clang++ \
    CXXFLAGS="-std=c++20 -Wall -Wextra -O1 -pthread -fno-rtti \
              -static-libgcc -static-libstdc++ \
              --target=x86_64-w64-mingw32 -fuse-ld=lld" \
    BOOTSTRAP_BIN="$tmp/beansc0.exe" stage0

file "$tmp/beansc0.exe" >"$tmp/file.out"
grep -q 'PE32+.*x86-64' "$tmp/file.out"
echo "  PE machine is x86-64"
wine "$tmp/beansc0.exe" --version >"$tmp/version.out"
grep -q '^beansc ' "$tmp/version.out"
echo "  --version runs"
wine "$tmp/beansc0.exe" target x86_64-pc-windows-gnu >"$tmp/target.out"
grep -q '^target x86_64-pc-windows-gnu' "$tmp/target.out"
echo "  target model runs"
if ! wine "$tmp/beansc0.exe" check compiler/beans/main.b \
        >"$tmp/check.raw" 2>"$tmp/check.err"; then
    cat "$tmp/check.raw" "$tmp/check.err" >&2
    exit 1
fi
tr -d '\r' <"$tmp/check.raw" >"$tmp/check.out"
if ! grep -q '^compiler/main\.b: ok$' "$tmp/check.out"; then
    echo "unexpected checker output:" >&2
    sed -n '1,20p' "$tmp/check.out" >&2
    cat "$tmp/check.err" >&2
    exit 1
fi
echo "  loader and checker run"
if ! wine "$tmp/beansc0.exe" build --emit ir examples/hello.b \
        -o "$tmp/host.ll" >"$tmp/build.out" 2>"$tmp/build.err"; then
    cat "$tmp/build.out" "$tmp/build.err" >&2
    exit 1
fi
grep -q 'target triple = "x86_64-pc-windows-gnu"' "$tmp/host.ll"
echo "  host build selects the Windows triple"

echo "ok Windows C++ stage 0: PE32+, host target, loader and checker"
