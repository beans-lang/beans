#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-int128.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking portable two-limb 128-bit arithmetic"
"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -Icompiler/bootstrap \
    test/portable_int128.cpp -o "$tmp/portable_int128"
"$tmp/portable_int128"

# The production header must never regain the host type this work replaces.
if sed 's://.*::' compiler/bootstrap/int128.h | grep -q '__int128'; then
    echo "compiler/bootstrap/int128.h depends on the host compiler's __int128" >&2
    exit 1
fi

echo "ok portable 128-bit arithmetic"
