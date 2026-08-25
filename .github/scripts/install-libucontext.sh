#!/usr/bin/env bash
# Put libucontext inside a musl cross sysroot that does not ship one.
#
#   install-libucontext.sh <libucontext-arch> <cross-tool-prefix> <sysroot>
#   install-libucontext.sh ppc64 /opt/tc/bin/powerpc64-linux-musl- /opt/tc/sysroot
#
# The fiber core switches stacks with hand-written asm on x86-64 and arm64 and
# with the POSIX ucontext family everywhere else. musl declares those functions
# without shipping them, so every other musl target links libucontext. Alpine
# hosts get it from `apk add libucontext-dev`, but the cross toolchains used for
# targets Alpine has no port of — big-endian PowerPC64 — carry only musl itself,
# so build the same library from a pinned source release into their sysroot.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <libucontext-arch> <cross-tool-prefix> <sysroot>" >&2
    exit 2
fi

arch=$1
prefix=$2
sysroot=$3

version=1.5.2
sha512=4c6fac619ba9b41a49ee6f3286fce77b1f1d0e7a03899c9bfa778d2fcdded72d3a8f54f2dc819be942f59dcc2457fd59441794c5898fce72e976c27aa2c07145

[[ -d "$sysroot/lib" ]] || {
    echo "sysroot has no lib directory: $sysroot" >&2
    exit 2
}

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/libucontext.XXXXXX")
trap 'rm -rf "$work"' EXIT

archive="$work/libucontext.tar.gz"
curl -fL --retry 5 --retry-all-errors --connect-timeout 20 \
    "https://github.com/kaniini/libucontext/archive/refs/tags/libucontext-$version.tar.gz" \
    -o "$archive"
echo "$sha512  $archive" | sha512sum -c -

mkdir -p "$work/src"
tar xzf "$archive" -C "$work/src" --strip-components=1

make -C "$work/src" -s \
    ARCH="$arch" CC="${prefix}gcc" AR="${prefix}ar"

# The archives, not the shared objects: a cross sysroot has no runtime loader
# path to install into, and the compiler links these statically anyway. The
# `_posix` archive carries the plain getcontext/setcontext/swapcontext names
# and stands on the base library, so link order stays `-lucontext_posix
# -lucontext` — the same order tools/link_compiler_ir.sh and the driver use.
install -m644 "$work/src/libucontext.a" "$work/src/libucontext_posix.a" \
    "$sysroot/lib/"
mkdir -p "$sysroot/include"
cp -R "$work/src/include/." "$sysroot/include/"
cp -R "$work/src/arch/$arch/include/." "$sysroot/include/"

echo "installed libucontext $version ($arch) into $sysroot"
