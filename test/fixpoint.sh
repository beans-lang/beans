#!/usr/bin/env bash
set -euo pipefail

# The self-hosting fixed point.
#
# A compiler written in its own language is correct about itself when it
# reproduces itself: the compiler built from these sources must build a
# compiler identical to itself, byte for byte. Two stages settle it — if
# stage 2 and stage 3 agree, every later stage agrees for the same reason.
#
# This is what a self-hosted compiler has in place of a second
# implementation to diff against. It catches the whole class of faults
# where the compiler miscompiles a construct that its own sources use,
# because such a fault reaches stage 3 through a stage 2 that no longer
# behaves like the compiler that built it.
#
# Both stages are written to the SAME path and moved aside afterwards. The
# compiler records its output path inside the binary it produces, so two
# stages built to different paths differ for that reason alone and would
# prove nothing.

cd "$(dirname "$0")/.."
compiler="${BEANSC:-$PWD/build/beansc}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fixpoint.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the self-hosting fixed point"

"$compiler" build src/main.b -o "$tmp/beansc" >"$tmp/stage2.log"
mv "$tmp/beansc" "$tmp/stage2"

"$tmp/stage2" build src/main.b -o "$tmp/beansc" >"$tmp/stage3.log"
mv "$tmp/beansc" "$tmp/stage3"

if ! cmp "$tmp/stage2" "$tmp/stage3"; then
    echo "the compiler does not reproduce itself" >&2
    shasum -a 256 "$tmp/stage2" "$tmp/stage3" >&2
    exit 1
fi

echo "ok stage 2 and stage 3 are identical" \
    "($(shasum -a 256 "$tmp/stage2" | cut -c1-16))"
