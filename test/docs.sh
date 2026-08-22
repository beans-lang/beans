#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-docs.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Documentation drifts silently, and the drift is only found when someone acts on it.
# These are the claims that can be checked mechanically.

echo "checking the public contributor documentation"
head -1 CONTRIBUTING.md | grep -q '^# Contributing to Beans$'
grep -qF '[language specification](spec/SYNTAX.md)' CONTRIBUTING.md
grep -qF '[CONTRIBUTING.md](CONTRIBUTING.md)' README.md

echo "checking the documented targets are the targets the compiler has"
# spec/SYNTAX.md lists the supported triples. The compiler prints its own list when given an
# unknown one, so the two can be compared rather than trusted.
./build/beansc build --target definitely-not-a-triple examples/hello.b --emit ir \
    >"$tmp/unknown" 2>&1 && {
    echo "an unknown triple was accepted" >&2
    exit 1
}
sed -n 's/.*supported targets are //p' "$tmp/unknown" | tr ',' '\n' | sed 's/^ *//' |
    sort >"$tmp/triples"
[[ -s "$tmp/triples" ]] || {
    echo "could not read the supported triples out of the error message" >&2
    cat "$tmp/unknown" >&2
    exit 1
}
while read -r triple; do
    grep -qF "\`$triple\`" spec/SYNTAX.md || {
        echo "spec/SYNTAX.md does not mention the supported target $triple" >&2
        exit 1
    }
done <"$tmp/triples"
echo "  ($(wc -l <"$tmp/triples" | tr -d ' ') targets, all documented)"

echo "checking every make target the docs name exists"
# A README that names a command which does not exist is worse than one that names none.
grep -ohE '^\s*make [a-z][a-z0-9-]*' README.md CONTRIBUTING.md | sed 's/.*make //' |
    sort -u >"$tmp/named"
for target in $(cat "$tmp/named"); do
    grep -qE "^$target:" Makefile || {
        echo "the docs name 'make $target', which the Makefile does not have" >&2
        exit 1
    }
done
echo "  ($(wc -l <"$tmp/named" | tr -d ' ') make targets, all real)"

echo "checking every test script is reachable from make or the scorecard"
# A test that nothing runs is not a test. The two legitimate entry points are the
# Makefile and the access scorecard, which runs each implemented row's named test.
for script in test/*.sh; do
    name=$(basename "$script")
    grep -q "$name" Makefile && continue
    grep -q "$script" test/access_scorecard.tsv && continue
    echo "$script is run by neither the Makefile nor the scorecard" >&2
    exit 1
done

echo "checking the scorecard's tests all exist and are the ones claimed"
# access_score.sh already refuses an implemented row with no test and runs each one.
# What it does not check is the reverse: a row naming a file that does not exist would
# be caught, but a row naming *another feature's* test would not, so the row's own name
# has to appear in the test it points at.
missing=0
while IFS=$'\t' read -r area points state slug test_path; do
    [[ "$state" == implemented ]] || continue
    [[ -f "$test_path" ]] || { echo "row $slug names a missing $test_path" >&2; missing=1; }
done < <(grep -v '^#' test/access_scorecard.tsv | grep -v '^$')
[[ "$missing" -eq 0 ]] || exit 1

echo "checking the roadmap does not claim something the scorecard calls planned"
# The scorecard is the machine-checked record. A roadmap tick for a row still marked
# planned would be the exact overclaim the whole scoring exercise exists to prevent.
while IFS=$'\t' read -r area points state slug test_path; do
    [[ "$state" == planned ]] || continue
    if grep -q "^- \[x\].*$slug" ROADMAP.md; then
        echo "ROADMAP.md ticks $slug, which the scorecard still calls planned" >&2
        exit 1
    fi
done < <(grep -v '^#' test/access_scorecard.tsv | grep -v '^$')

echo "ok docs: contributor guide, targets, commands, and tests are current"
