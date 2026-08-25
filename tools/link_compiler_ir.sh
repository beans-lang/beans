#!/usr/bin/env bash
# Link compiler IR produced on a supported host into a native compiler.
#
# This closes the first-release gap for hosts that only exist in containers:
# a released host compiler emits target IR, then the target container links it
# with the public runtime and encoding bridges. No stage-0 source is involved.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <compiler.ll> <compiler_ffi.c> <output>" >&2
    exit 2
fi

ir=$1
ffi=$2
output=$3
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cc=${BEANS_CC:-clang}

[[ -f "$ir" ]] || { echo "compiler IR is missing: $ir" >&2; exit 2; }
[[ -f "$ffi" ]] || { echo "compiler FFI source is missing: $ffi" >&2; exit 2; }
command -v "$cc" >/dev/null 2>&1 || {
    echo "Clang is missing: $cc" >&2
    exit 2
}

mkdir -p "$(dirname "$output")"
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-compiler-link.XXXXXX")
trap 'rm -rf "$work"' EXIT

common=(-O2 -pthread)
# Clang in the ARMv6 container inherits a newer distro default even though the
# process runs under an ARM1176 QEMU CPU. Pin every linked object to ARMv6 so
# the first compiler can run before it is able to rebuild itself normally.
if [[ $(uname -m) == armv6l ]]; then
    common+=(
        -march=armv6 -marm -mfpu=vfp -mfloat-abi=hard
        -mno-unaligned-access
    )
fi
"$cc" "${common[@]}" -DBEANS_RT_PROFILE=3 -DBEANS_RT_DECIMAL=1 \
    -Wno-override-module -c "$repo/runtime/beans_rt.c" -o "$work/runtime.o"
"$cc" "${common[@]}" -fvisibility=hidden \
    -c "$repo/runtime/encoding/beans_enc_json.c" -o "$work/json.o"
"$cc" -x c++ -std=c++17 -fno-exceptions -fno-rtti \
    "${common[@]}" -fvisibility=hidden \
    -c "$repo/runtime/encoding/beans_enc_xml.cpp" -o "$work/xml.o"

libraries=(-lm)
case "$(uname -m)" in
    arm*) libraries+=(-latomic) ;;
esac
# The fiber core uses hand-written asm on arm64 and x86-64 and the POSIX
# ucontext family everywhere else. musl declares those functions without
# shipping them, so those hosts link Alpine's libucontext — the `_posix`
# archive carries the plain names and stands on the base library, so it
# comes first. Same rule the compiler's own linker step applies.
case "$(uname -m)" in
    aarch64 | arm64 | x86_64) ;;
    *)
        # Keyed on the archive itself: a glibc host has no libucontext and
        # needs none, and a musl host missing it fails at the link with the
        # undefined getcontext it actually has.
        if [ -e /usr/lib/libucontext_posix.a ]; then
            libraries+=(-lucontext_posix -lucontext)
        fi
        ;;
esac

"$cc" "${common[@]}" -Wno-override-module \
    "$ir" "$ffi" "$work/runtime.o" "$work/json.o" "$work/xml.o" \
    "${libraries[@]}" -o "$output"
chmod 0755 "$output"
"$output" --version
