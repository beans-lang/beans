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
#   1. The compiler every other gate runs against behaves like the fixed
#      point. `make` builds stage 1 and stops, so build/beansc is whatever
#      the bootstrap compiler produced -- and every behavioural gate in this
#      repo then runs against that binary. Nothing checked it. A bootstrap
#      that miscompiles the compiler therefore gave every suite a compiler
#      that was never validated at all, and the failures landed as "main is
#      broken" on whatever the reader was holding.
#
#      That is not hypothetical. Building this tree with
#      build/beansc-boot-0.1.30 -- documented as "a known-good bootstrap" --
#      produces a stage 1 whose tree interpreter drops one release in
#      test/cases/parity/record_place.b, so test/backend_parity.sh fails on
#      unmodified sources. One self-rebuild washes it out: the stage 2 that
#      stage 1 builds is byte-identical to the compiler a good bootstrap
#      produces. The old form of this gate passed on that binary, because
#      stage 2 and stage 3 agreed with each other while neither agreed with
#      the compiler under test.
#
#   2. The fixed point is stable: stage 2 and stage 3 agree.
#
# Claim 1 is deliberately NOT "stage 1 and stage 2 are the same bytes".
# That was tried and it is the wrong claim. Stage 1 and stage 2 are the same
# *program* -- both are these sources -- but they are not the same *build*:
# stage 1's machine code was emitted by the bootstrap and stage 2's by stage
# 1, so anything that legitimately varies between two correct compilers
# separates their bytes while separating nothing that matters. Measured: with
# the released 0.1.38 as the bootstrap the two are byte-identical on
# arm64-apple-darwin and differ on x86_64-unknown-linux-gnu, on the same
# sources. A gate cannot tell that apart from a real fault by comparing
# bytes, so it must not try.
#
# What it compares instead is what the two must agree on because they are the
# same program: for every parity case, the answer the tree interpreter gives,
# both output streams, the exit status, and the LLVM IR each one emits. A
# bootstrap that miscompiled the compiler changes one of those; a different
# but correct build changes none of them. Both halves are needed and neither
# is redundant -- the 0.1.30 defect above is invisible in the emitted IR and
# shows only in the interpreter, and a defect in the emitter would be the
# other way round.
#
# The corpus is test/cases/parity/*.b because those cases exist to expose
# exactly this: ownership, release order, backend disagreement. On the 0.1.30
# stage 1 the check fails on 1 of 40, which is also the reason the corpus is
# all of them and not a chosen few.
#
# Two of the forty are excluded from the interpreter half, by name, and this
# is the whole reason: bind_release.b builds 40,000-node lists and 3,000-node
# cycles and costs 97 seconds under the tree interpreter, sort_by_key_paths.b
# costs 11, and every one of the other 38 costs 0.03. Running the pair on both
# compilers would put nearly four minutes on two CI jobs on every pull request.
# They stay in the IR half, test/backend_parity.sh still runs both of them
# against stage 1, and the exclusion is pinned below so a third name cannot
# join it quietly.
#
# What claim 1 cannot see, said plainly: a compiler that is wrong *and*
# reproduces that wrongness in everything it emits. No rebuild separates
# that -- that is what the behavioural suites are for. The point is that they
# now run against a binary something has checked.
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

# The corpus can only shrink by accident -- a moved directory leaves the glob
# unmatched and every loop below runs zero times while still printing "ok".
# Below this many cases the check is not weaker, it is absent, so it refuses.
corpus_floor=30

# Excluded from the interpreter half only, for cost: 97s and 11s against 0.03s
# for every other case. They stay in the IR half below.
slow_cases="bind_release.b sort_by_key_paths.b"

# same_program <a> <b> -- do two builds of these sources behave alike?
#
# Runs each parity case on both and compares the answer, both streams and the
# exit status; then has each emit LLVM IR for it and compares that. The IR is
# written to the SAME path by both, because the emitted text names its own
# output file: a different -o would differ for that reason and say nothing.
same_program() {
    local a=$1 b=$2 f n=0 ran=0 slow=0 bad=0 sa sb
    local w="$tmp/corpus"
    mkdir -p "$w"

    for f in test/cases/parity/*.b; do
        [ -e "$f" ] || continue
        n=$((n + 1))

        case " $slow_cases " in
            *" $(basename "$f") "*) slow=$((slow + 1)) ;;
            *)
                ran=$((ran + 1))
                sa=0; sb=0
                "$a" run "$f" >"$w/a.out" 2>"$w/a.err" || sa=$?
                "$b" run "$f" >"$w/b.out" 2>"$w/b.err" || sb=$?
                if [ "$sa" != "$sb" ] || ! cmp -s "$w/a.out" "$w/b.out" ||
                   ! cmp -s "$w/a.err" "$w/b.err"; then
                    bad=$((bad + 1))
                    echo "  answers differ: $f (exit $sa vs $sb)" >&2
                    diff "$w/a.out" "$w/b.out" | sed -n '1,8p' >&2 || true
                    diff "$w/a.err" "$w/b.err" | sed -n '1,8p' >&2 || true
                    continue
                fi
                ;;
        esac

        sa=0; sb=0
        "$a" build "$f" --emit ir -o "$w/ir.ll" >"$w/a.log" 2>&1 || sa=$?
        if [ -e "$w/ir.ll" ]; then mv -f "$w/ir.ll" "$w/a.ll"; else : >"$w/a.ll"; fi
        "$b" build "$f" --emit ir -o "$w/ir.ll" >"$w/b.log" 2>&1 || sb=$?
        if [ -e "$w/ir.ll" ]; then mv -f "$w/ir.ll" "$w/b.ll"; else : >"$w/b.ll"; fi
        if [ "$sa" != "$sb" ] || ! cmp -s "$w/a.ll" "$w/b.ll"; then
            bad=$((bad + 1))
            echo "  emitted IR differs: $f (exit $sa vs $sb)" >&2
            diff "$w/a.ll" "$w/b.ll" | sed -n '1,8p' >&2 || true
        fi
    done

    if [ "$n" -lt "$corpus_floor" ]; then
        echo "" >&2
        echo "the parity corpus is $n programs, below the floor of" \
             "$corpus_floor: test/cases/parity/*.b matched almost nothing," >&2
        echo "so this check did not run. Fix the path rather than the floor." >&2
        exit 1
    fi
    # The exclusion list is a cost decision, so it is pinned: a case renamed
    # out of it silently drops to zero exclusions and a case added silently
    # drops coverage. Either way the number moves and this refuses.
    if [ "$slow" -ne 2 ]; then
        echo "" >&2
        echo "$slow of the corpus matched the interpreter-half exclusion list," \
             "expected 2." >&2
        echo "The list is \`$slow_cases\`, excluded only for their cost under" >&2
        echo "the tree interpreter. Update the list and this count together," >&2
        echo "with the measurement that justifies it." >&2
        exit 1
    fi
    if [ "$bad" -ne 0 ]; then
        echo "" >&2
        echo "$bad of $n corpus programs came out differently." >&2
        return 1
    fi
    corpus_size=$n
    corpus_ran=$ran
    return 0
}

# Claim 1: the compiler every other gate runs against behaves like the fixed
# point it builds.
#
# Only checkable when the compiler under test is the tree's own $(BIN):
# nothing in this repo invokes the gate any other way today, so the check is
# expected to run every time -- and it says so out loud when it does not,
# because a check that quietly excuses itself is the shape this whole gate
# exists to close.
corpus_size=0
corpus_ran=0
if [ "$compiler" = "$PWD/$bin" ]; then
    if cmp -s "$bin" "$tmp/stage2"; then
        echo "ok $bin is the fixed point it builds, byte for byte"
    else
        echo "note: $bin and the stage 2 it builds are not the same bytes" >&2
        digest "$bin" "$tmp/stage2" >&2
        echo "That alone is not a fault: stage 1 was emitted by the bootstrap" >&2
        echo "and stage 2 by stage 1, and two correct builds of one program" >&2
        echo "may differ. Checking what they must agree on instead." >&2
        if ! same_program "$PWD/$bin" "$tmp/stage2"; then
            echo "" >&2
            echo "$bin does not behave like the compiler it builds." >&2
            echo "" >&2
            echo "\`make\` builds stage 1 and stops, so this is the binary every" >&2
            echo "other suite runs against. Its answers cannot be trusted, and a" >&2
            echo "failure anywhere else is more likely to be this than the" >&2
            echo "sources." >&2
            echo "" >&2
            echo "The cause is the bootstrap compiler BEANSC_BOOT pointed at: it" >&2
            echo "miscompiles these sources, and one self-rebuild washes it out." >&2
            echo "Rebuild from a bootstrap that passes this gate, or promote the" >&2
            echo "stage 2 above and rebuild from that." >&2
            exit 1
        fi
        echo "ok $bin and its stage 2 agree on $corpus_size corpus programs:" \
             "emitted IR for all of them, and answers, both streams and exit" \
             "status for the $corpus_ran run under the interpreter"
    fi
else
    echo "note: BEANSC is $compiler, not $PWD/$bin, so the stage-1 check is" >&2
    echo "skipped -- it is a claim about the binary the other suites use, and" >&2
    echo "that is not the binary under test here. Only the stage 2 vs stage 3" >&2
    echo "claim below was made." >&2
fi

# Claim 2: the fixed point is stable.
if ! cmp "$tmp/stage2" "$tmp/stage3"; then
    echo "the compiler does not reproduce itself" >&2
    digest "$tmp/stage2" "$tmp/stage3" >&2
    exit 1
fi

echo "ok stage 2 and stage 3 are identical" \
    "($(digest "$tmp/stage2" | cut -c1-16))"
