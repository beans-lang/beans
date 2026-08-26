#!/usr/bin/env bash
# The native backend's declared gaps, held as a tracked list rather than 144
# refusals scattered through the emitter.
#
# Most of these are not language limits. The checker accepts the program, the
# interpreter runs it and prints the right answer, and only `beansc build`
# refuses — the same shape as the class-to-interface return upcast this tree
# fixed. A program that runs but will not build is a bug, and every untriaged
# line in test/emitter_gaps.tsv is a candidate for one.
#
# This gate does two things:
#
#   1. holds the inventory current, so adding or removing an emitter refusal
#      has to be recorded, and the count cannot drift unnoticed
#   2. runs a probe for each gap triaged `interpreter-ok` and checks the claim
#      still holds — the interpreter runs it, the build refuses with the
#      recorded message
#
# A probe that starts building is good news, and it fails this gate on
# purpose: the gap is closed, so its line and its probe should go.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-emitter-gaps.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

python3 tools/emitter_gaps.py --check

probes=0
for source in test/cases/emitter_gaps/*.b; do
    name=$(basename "$source" .b)
    want=$(sed -n 's|^// gap: ||p' "$source" | head -1)
    if [ -z "$want" ]; then
        echo "$source has no '// gap:' line naming the message it expects" >&2
        exit 1
    fi
    # the interpreter has to run it: that is what makes this a gap in the
    # backend rather than something the language does not offer
    if ! ./build/beansc run "$source" >"$tmp/$name.run" 2>&1; then
        echo "$source no longer runs in the interpreter:" >&2
        cat "$tmp/$name.run" >&2
        exit 1
    fi
    if [ ! -s "$tmp/$name.run" ]; then
        echo "$source printed nothing, so it proved nothing" >&2
        exit 1
    fi
    if ./build/beansc build "$source" -o "$tmp/$name.bin" >"$tmp/$name.build" 2>&1; then
        echo "$source now builds — the gap is closed." >&2
        echo "Drop its line from test/emitter_gaps.tsv, delete the probe," >&2
        echo "and regenerate with tools/emitter_gaps.py." >&2
        exit 1
    fi
    if ! grep -Fq "$want" "$tmp/$name.build"; then
        echo "$source: the build refused with a different message" >&2
        echo "  wanted: $want" >&2
        echo "  got:" >&2
        grep -o 'LLVM emitter.*' "$tmp/$name.build" >&2 || cat "$tmp/$name.build" >&2
        exit 1
    fi
    echo "  gap holds: $name"
    probes=$((probes + 1))
done

# Every shape triaged `interpreter-ok` should have a probe standing behind it,
# or the triage is a claim nobody checks.
claimed=$(awk -F'\t' '$4 == "interpreter-ok" {print $2}' test/emitter_gaps.tsv |
          sort -u | wc -l | tr -d ' ')
if [ "$probes" -lt "$claimed" ]; then
    echo "$claimed shapes are triaged interpreter-ok but only $probes probes exist" >&2
    echo "add a probe under test/cases/emitter_gaps/ for each" >&2
    exit 1
fi

echo "ok emitter gaps: inventory current, $probes probes hold"
