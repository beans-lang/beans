#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-compiler-arch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
require=${BEANS_REQUIRE_ALL_TARGETS:-0}

echo "checking both compilers can emit every non-native compiler object"
targets=(
    i686-unknown-linux-gnu
    armv7-unknown-linux-gnueabihf
    arm-unknown-linux-gnueabi
    arm-unknown-linux-gnueabihf
    loongarch64-unknown-linux-gnu
    loongarch64-unknown-linux-musl
    powerpc-unknown-linux-gnu
    powerpc64-unknown-linux-gnu
    # The big-endian musl target needs its matching C++ sysroot. The hosted
    # ppc64musl job owns it and runs the compiler under QEMU as well.
    s390x-unknown-linux-gnu
    i686-pc-windows-gnu
)

for target in "${targets[@]}"; do
    safe=${target//-/_}
    # A backend alone is not enough for src/main.b: its C imports emit a
    # small FFI source file that needs the target's libc headers too. An arm64
    # runner can lower i686 instructions without having an i686 sysroot, which
    # used to pass this probe and fail later in stdint.h.
    if ! printf '#include <stdint.h>\n' | \
            clang --target="$target" -x c -c - \
                -o "$tmp/probe.$safe.o" >/dev/null 2>&1; then
        if [[ "$require" == 1 ]]; then
            echo "clang has no usable backend and headers for required target $target" >&2
            exit 1
        fi
        echo "  skip $target (host clang has no usable backend and headers)"
        continue
    fi
    for compiler in beansc; do
        object="$tmp/$compiler.$safe.o"
        "./build/$compiler" build --target "$target" --emit obj \
            src/main.b -o "$object" >/dev/null
        test -s "$object"
    done
    echo "  ok $target"
done

echo "ok non-native compiler IR and target objects"
