#!/usr/bin/env bash
# Locate — or fetch — an LLVM-MinGW toolchain covering every Windows target,
# and print its bin directory on stdout.
#
#   eval "export PATH=$(bash test/windows_toolchain.sh):\$PATH"
#
# Why not the distro's mingw-w64: it ships x86-64 and i686 only. There is no
# aarch64 MinGW in Debian or Ubuntu, so Windows on ARM cannot be linked with it
# at all. LLVM-MinGW carries clang, lld and a CRT for all three in one archive,
# which is also why one toolchain covers the whole matrix instead of three.
#
# It is installed *beside* the checkout, never into the system: this script is
# run on developer machines as well as CI, and a toolchain that edits the host
# is not something a test script should do behind someone's back. The directory
# is gitignored.
set -euo pipefail

VERSION=${BEANS_LLVM_MINGW_VERSION:-20260616}

root=$(cd "$(dirname "$0")/.." && pwd -P)
dest=${BEANS_TOOLCHAIN_DIR:-$root/toolchains}

# The archive is picked by the machine this runs *on*; every archive can emit
# for all three Windows architectures regardless.
#
# The CRT is msvcrt where a msvcrt archive exists, because that is what the
# existing green x86-64 target already links against and this file is meant to
# add architectures without moving anything under the one that works. Upstream
# publishes no msvcrt build for an ARM64 or macOS host, so those fall back to
# ucrt — stated here rather than discovered as a 404 in the middle of CI.
host_machine=$(uname -m)
case "$(uname -s)" in
    Linux)
        ext="tar.xz"
        case "$host_machine" in
            aarch64 | arm64) host_tag="ubuntu-22.04-aarch64"; CRT=ucrt ;;
            *)               host_tag="ubuntu-22.04-x86_64";  CRT=msvcrt ;;
        esac
        ;;
    Darwin)
        ext="tar.xz"; host_tag="macos-universal"; CRT=ucrt
        ;;
    *)
        ext="zip"
        case "$host_machine" in
            aarch64 | arm64) host_tag="aarch64"; CRT=ucrt ;;
            i686 | i386)     host_tag="i686";    CRT=msvcrt ;;
            *)               host_tag="x86_64";  CRT=msvcrt ;;
        esac
        ;;
esac
CRT=${BEANS_LLVM_MINGW_CRT:-$CRT}

name="llvm-mingw-${VERSION}-${CRT}-${host_tag}"
bin="$dest/$name/bin"

# Already unpacked, or already on PATH from a previous install: say so and stop.
if [[ -x "$bin/clang" || -x "$bin/clang.exe" ]]; then
    echo "$bin"
    exit 0
fi

if [[ "${BEANS_TOOLCHAIN_OFFLINE:-0}" == "1" ]]; then
    echo "no LLVM-MinGW at $bin and BEANS_TOOLCHAIN_OFFLINE=1" >&2
    exit 1
fi

url="https://github.com/mstorsjo/llvm-mingw/releases/download/${VERSION}/${name}.${ext}"
mkdir -p "$dest"
echo "fetching $name" >&2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/tc.$ext" "$url"
case "$ext" in
    tar.xz) tar -xf "$tmp/tc.$ext" -C "$dest" ;;
    zip)    unzip -q "$tmp/tc.$ext" -d "$dest" ;;
esac

if [[ ! -x "$bin/clang" && ! -x "$bin/clang.exe" ]]; then
    echo "unpacked $name but found no clang in $bin" >&2
    exit 1
fi
echo "$bin"
