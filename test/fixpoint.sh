#!/usr/bin/env bash
set -euo pipefail

# The self-hosting fixed point.
#
# A compiler written in its own language is correct about itself when it
# reproduces itself: the compiler built from these sources must build a
# compiler identical to itself, byte for byte.
#
# This is what a self-hosted compiler has in place of a second
# implementation to diff against. It catches the whole class of faults
# where the compiler miscompiles a construct that its own sources use,
# because such a fault reaches stage 3 through a stage 2 that no longer
# behaves like the compiler that built it.
#
# There are two claims here, and until now this gate only made the second.
#
#   1. build/beansc IS the fixed point. `make` builds stage 1 and stops, so
#      build/beansc is whatever the bootstrap compiler produced -- and every
#      behavioural gate in this repo then runs against that binary. Nothing
#      checked it. A bootstrap that miscompiles the compiler therefore gave
#      every suite a compiler that was never validated at all, and the
#      failures landed as "main is broken" on whatever the reader was
#      holding.
#
#      That is not hypothetical. Building this tree with
#      build/beansc-boot-0.1.30 -- documented as "a known-good bootstrap" --
#      produces a stage 1 whose tree interpreter drops one release in
#      test/cases/parity/record_place.b, so test/backend_parity.sh fails on
#      unmodified sources. One self-rebuild washes it out: that stage 1 and
#      the correct compiler are 209 KB apart, and the stage 2 it builds is
#      byte-identical to the compiler a good bootstrap produces. The old form
#      of this gate passed on that binary, because stage 2 and stage 3 agreed
#      with each other while neither agreed with the compiler under test.
#
#   2. The fixed point is stable: stage 2 and stage 3 agree.
#
# Both stages, and the make-time build of build/beansc itself, use the SAME
# output path and the SAME flags. That is load-bearing, not tidiness: the
# compiler records its output path inside the binary it produces, so the same
# sources built to a different -o differ for that reason alone. Measured here:
# the same compiler, same sources, same `--release`, built to build/beansc.new
# and to another path, produces two different digests. So the stages are built
# at build/beansc.new -- the exact path the Makefile's $(BIN) rule uses -- and
# moved aside afterwards, which makes all three binaries comparable.

cd "$(dirname "$0")/.."

# The Makefile's $(BIN); on Windows it carries the .exe suffix.
bin=build/beansc
[ -e "$bin" ] || bin=build/beansc.exe
staged="$bin.new"

compiler="${BEANSC:-$PWD/$bin}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fixpoint.XXXXXX")
trap 'rm -rf "$tmp" "$staged"' EXIT

echo "checking the self-hosting fixed point"

"$compiler" build --release src/main.b -o "$staged" >"$tmp/stage2.log"
mv "$staged" "$tmp/stage2"

"$tmp/stage2" build --release src/main.b -o "$staged" >"$tmp/stage3.log"
mv "$staged" "$tmp/stage3"

# macOS ships shasum but not sha256sum; Git Bash on Windows is the reverse.
digest() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        sha256sum "$@"
    fi
}

# Claim 1: the compiler every other gate runs against is the fixed point.
#
# Only checkable when the compiler under test is the tree's own $(BIN): a
# BEANSC pointing elsewhere was built to a different path, so its bytes would
# differ for that reason and say nothing. Nothing in this repo invokes the gate
# that way today, so the check is expected to run every time -- and it says so
# out loud when it does not, because a check that quietly excuses itself is the
# shape this whole gate exists to close.
if [ "$compiler" = "$PWD/$bin" ]; then
    if ! cmp "$bin" "$tmp/stage2"; then
        echo "" >&2
        echo "$bin is not the fixed point: the compiler it builds is not itself." >&2
        digest "$bin" "$tmp/stage2" >&2
        echo "" >&2
        echo "\`make\` builds stage 1 and stops, so this is the binary every other" >&2
        echo "suite runs against. Its answers cannot be trusted, and a failure" >&2
        echo "anywhere else is more likely to be this than the sources." >&2
        echo "" >&2
        echo "The usual cause is the bootstrap compiler BEANSC_BOOT pointed at:" >&2
        echo "it miscompiles these sources, and one self-rebuild washes it out." >&2
        echo "Rebuild from a bootstrap that passes this gate, or promote the" >&2
        echo "stage 2 above and rebuild from that." >&2
        exit 1
    fi
    echo "ok $bin is the fixed point it builds"
else
    echo "note: BEANSC is $compiler, not $PWD/$bin, so the stage-1 check is" >&2
    echo "skipped -- a compiler built to another path differs in its bytes for" >&2
    echo "that reason alone. Only the stage 2 vs stage 3 claim below was made." >&2
fi

# Claim 2: the fixed point is stable.
if ! cmp "$tmp/stage2" "$tmp/stage3"; then
    echo "the compiler does not reproduce itself" >&2
    digest "$tmp/stage2" "$tmp/stage3" >&2
    exit 1
fi

echo "ok stage 2 and stage 3 are identical" \
    "($(digest "$tmp/stage2" | cut -c1-16))"
