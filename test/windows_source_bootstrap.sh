#!/usr/bin/env bash
# Build the C++ stage 0 on Windows, then prove it reaches the self-hosted fixed
# point. This runs on the real Windows matrix, once for x64, WOW64/i686 and ARM64.
set -euo pipefail

cd "$(dirname "$0")/.."

TRIPLE=${1:-x86_64-pc-windows-gnu}
OUT=${2:-build/windows_source_bootstrap}
CXX=${CXX:-clang++}
smoke_only=${BEANS_SOURCE_SMOKE_ONLY:-0}

case "$TRIPLE" in
    x86_64-pc-windows-gnu)
        arch=x86_64; canonical=$TRIPLE; clang_triple=$TRIPLE; host_flag= ;;
    i686-pc-windows-gnu)
        arch=i686; canonical=$TRIPLE; clang_triple=$TRIPLE; host_flag= ;;
    x86_64-pc-windows-gnullvm)
        arch=x86_64; canonical=$TRIPLE; clang_triple=x86_64-pc-windows-gnu
        host_flag=-DBEANS_HOST_GNULLVM=1 ;;
    aarch64-pc-windows-gnullvm | aarch64-pc-windows-gnu)
        arch=aarch64; canonical=aarch64-pc-windows-gnullvm
        clang_triple=aarch64-pc-windows-gnu
        host_flag=-DBEANS_HOST_GNULLVM=1 ;;
    x86_64-pc-windows-msvc)
        arch=x86_64; canonical=$TRIPLE; clang_triple=$TRIPLE; host_flag= ;;
    i686-pc-windows-msvc)
        arch=i686; canonical=$TRIPLE; clang_triple=$TRIPLE; host_flag= ;;
    aarch64-pc-windows-msvc)
        arch=aarch64; canonical=$TRIPLE; clang_triple=$TRIPLE; host_flag= ;;
    *)
        echo "unsupported Windows bootstrap target '$TRIPLE'" >&2
        exit 2
        ;;
esac

command -v "$CXX" >/dev/null || {
    echo "Windows source bootstrap needs $CXX on PATH" >&2
    exit 1
}
command -v clang >/dev/null || {
    echo "Windows source bootstrap needs clang on PATH" >&2
    exit 1
}

mkdir -p "$OUT"
rm -f "$OUT"/beansc0.exe "$OUT"/stage1.exe \
    "$OUT"/stage2.exe "$OUT"/stage3.exe

echo "building C++ stage 0 for $TRIPLE"
extra_flags=()
if [[ "$TRIPLE" != *-msvc ]]; then
    extra_flags=(-pthread -static-libgcc -static-libstdc++)
fi
"$CXX" -std=c++20 -Wall -Wextra -O2 -fno-rtti \
    "${extra_flags[@]}" --target="$clang_triple" $host_flag \
    -fuse-ld=lld \
    compiler/bootstrap/*.cpp -o "$OUT/beansc0.exe"

runtime_path=$PWD/runtime/beans_rt.c
stdlib_path=$PWD/stdlib/std
if command -v cygpath >/dev/null; then
    runtime_path=$(cygpath -w "$runtime_path")
    stdlib_path=$(cygpath -w "$stdlib_path")
fi
export BEANS_RUNTIME=${BEANS_RUNTIME:-$runtime_path}
export BEANS_STDLIB=${BEANS_STDLIB:-$stdlib_path}
export BEANS_CC=${BEANS_CC:-clang}

"$OUT/beansc0.exe" target "$TRIPLE" >"$OUT/target.raw"
tr -d '\r' <"$OUT/target.raw" >"$OUT/target.out"
grep -q "^target $canonical$" "$OUT/target.out"
if ! "$OUT/beansc0.exe" check compiler/beans/main.b >"$OUT/check.raw" 2>&1; then
    echo "the Windows stage-0 compiler could not check compiler/beans/main.b:" >&2
    tr -d '\r' <"$OUT/check.raw" >&2
    exit 1
fi
tr -d '\r' <"$OUT/check.raw" >"$OUT/check.out"
if ! grep -q ': ok$' "$OUT/check.out"; then
    echo "the Windows stage-0 checker did not print ok:" >&2
    cat "$OUT/check.out" >&2
    exit 1
fi
if ! "$OUT/beansc0.exe" run examples/ffi.b >"$OUT/ffi.raw" 2>&1; then
    echo "the Windows stage-0 interpreter failed examples/ffi.b:" >&2
    tr -d '\r' <"$OUT/ffi.raw" >&2
    exit 1
fi
tr -d '\r' <"$OUT/ffi.raw" >"$OUT/ffi.out"
cmp test/cases/ffi.out "$OUT/ffi.out"
"$OUT/beansc0.exe" build --emit ir examples/hello.b -o "$OUT/host.ll"
grep -q "target triple = \"$clang_triple\"" "$OUT/host.ll"

if [[ "$smoke_only" == 1 ]]; then
    echo "ok Windows source stage 0: $arch target, checker, FFI, and IR"
    exit 0
fi

echo "building self-host stages 1 to 3"
"$OUT/beansc0.exe" build --linker lld compiler/beans/main.b -o "$OUT/stage1.exe"
"$OUT/stage1.exe" build --linker lld compiler/beans/main.b -o "$OUT/stage2.exe"
"$OUT/stage2.exe" build --linker lld compiler/beans/main.b -o "$OUT/stage3.exe"
"$OUT/stage2.exe" llvm compiler/beans/main.b >"$OUT/stage2.ll"
"$OUT/stage3.exe" llvm compiler/beans/main.b >"$OUT/stage3.ll"

if ! cmp -s "$OUT/stage2.ll" "$OUT/stage3.ll"; then
    echo "Windows source bootstrap did not reach an IR fixed point" >&2
    ls -l "$OUT/stage2.ll" "$OUT/stage3.ll" >&2
    exit 1
fi

"$OUT/stage3.exe" build --linker lld examples/hello.b -o "$OUT/hello.exe"
[[ $("$OUT/hello.exe" | tr -d '\r') == "hello from beans" ]]

echo "ok Windows source bootstrap: $arch stage 0 -> fixed point -> hello"
