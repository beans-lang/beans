#!/usr/bin/env bash
# Differential conformance for `decimal` against Python's decimal module.
#
# A self-hosted compiler has no second implementation to diff `decimal` against,
# so it is checked the way the other fuzzers check the language: against an
# independent implementation of the same specification. The operands come from
# the IBM General Decimal Arithmetic test suite (Mike Cowlishaw's .decTest
# files, whose spec became the decimal part of IEEE 754-2008); every expected
# answer is recomputed by Python's `decimal` at the beans contract — 38
# significant digits, ROUND_HALF_EVEN. IBM chose the operands, Python computes
# the answers, and beans never sees either column: it reads operands and prints
# `id<TAB>answer`, which is diffed on both backends.
#
# The operands are vendored in test/fixtures/decimal_cases.tsv so the gate needs
# no CPython source tree — every case in the eligible suite, not a sample, or a
# reverted zero-scale fix would slip past a gate that dropped the very cases
# that caught it. Regenerate the fixture from an installed CPython with
#
#   tools/decimal_conformance.py emit --out test/fixtures/decimal_cases.tsv
#
# and sweep the whole live suite (not just the vendored operands) with
#
#   tools/decimal_conformance.py run --decdata <cpython>/test/decimaltestdata
set -euo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null 2>&1 || {
    echo "decimal_conformance: python3 is required" >&2
    exit 2
}
[ -x build/beansc ] || {
    echo "decimal_conformance: build/beansc not built" >&2
    exit 1
}

cases="test/fixtures/decimal_cases.tsv"
[ -f "$cases" ] || {
    echo "decimal_conformance: missing case fixture $cases" >&2
    exit 1
}

# The vendored fixture is the whole eligible suite. A gate that quietly ran a
# handful of cases would pass while testing almost nothing, so the count the
# tool reports is held to the fixture's own line count, and that count is held
# above a floor no accidental truncation stays under.
fixture_rows=$(grep -c . "$cases")
if [ "$fixture_rows" -lt 12000 ]; then
    echo "decimal_conformance: fixture has only $fixture_rows rows (expected the full ~12,540-case suite)" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-decimal-conformance.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

log="$tmp/report.txt"
python3 tools/decimal_conformance.py run \
    --cases "$cases" --beansc build/beansc --lanes both >"$log" 2>&1 || {
    echo "decimal_conformance: replay failed" >&2
    cat "$log" >&2
    exit 1
}
cat "$log"

# The tool exits 0 only when it finds no wrong value and no backend
# disagreement, so the exit code above already carries the verdict. These
# assertions make the two properties the gate is named for impossible to lose
# silently to a future change in the tool's output, and pin the case count to
# the fixture so a shrunk fixture cannot pass.
ran=$(sed -n 's/^  cases \([0-9][0-9]*\) .*/\1/p' "$log")
if [ "$ran" != "$fixture_rows" ]; then
    echo "decimal_conformance: ran $ran cases, fixture has $fixture_rows" >&2
    exit 1
fi
grep -q "interpreter and native agree byte for byte" "$log" || {
    echo "decimal_conformance: backends did not agree byte for byte" >&2
    exit 1
}
grep -q "wrong values 0   mismatched 0" "$log" || {
    echo "decimal_conformance: a case produced a wrong value" >&2
    exit 1
}

echo "ok decimal conformance: $ran IBM cases, both backends, vs Python decimal at 38 digits half-even"
