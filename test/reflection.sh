#!/usr/bin/env bash
# The reflection behaviour cases, on both backends, against their goldens.
#
# These cases existed and their goldens did not. test/cases/reflect_*.b were
# named only by test/sanitize.sh, whose run_asan builds and runs a program and
# checks the sanitizers stayed quiet — it never opens the .out beside it. So
# seven checked-in golden files described behaviour nothing compared anything
# to, and reflection's answers were covered only by the generated differential
# in test/reflection_fuzz.sh, which pins the two backends to each other and
# not to any expected string.
#
# This runs each case on the interpreter and on a native build and diffs both
# against the golden, which is the claim the goldens were written to make: not
# that the backends agree, but that reflection answers these exact strings.
#
# The value cases carry #163 — a box records the class a value IS, not the
# type of the binding it was handed — because that rule is a string in a
# golden and nothing else can see it.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-reflection.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# run_both <case-name> — interpreter and native, both against the golden
run_both() {
    local name=$1
    local source="test/cases/$name.b"
    local golden="test/cases/$name.out"
    if [ ! -f "$source" ]; then
        echo "missing reflection case $source" >&2
        exit 1
    fi
    if [ ! -f "$golden" ]; then
        echo "missing golden $golden" >&2
        exit 1
    fi
    ./build/beansc run "$source" >"$tmp/$name.interp"
    ./build/beansc build "$source" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    BEANS_NO_POOL=1 "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "$golden" "$tmp/$name.interp"
    diff -u "$golden" "$tmp/$name.native.out"
    echo "  ok $source ($(wc -l <"$tmp/$name.interp" | tr -d ' ') lines)"
}

echo "checking reflection answers, interpreter and native, against goldens"
run_both reflect_type
run_both reflect_members
run_both reflect_fields
run_both reflect_calls
run_both reflect_construct
run_both reflect_annotations
run_both reflect_value

# Every reflect_* case in test/cases has to be run above. One added and
# forgotten would go back to being a golden nothing compares against, which
# is the hole this script exists to close.
listed=7
present=$(find test/cases -maxdepth 1 -name 'reflect_*.b' | wc -l | tr -d ' ')
if [ "$present" != "$listed" ]; then
    echo "test/cases holds $present reflect_* cases but $listed are run" >&2
    echo "add the new case to test/reflection.sh" >&2
    exit 1
fi

echo "ok reflection goldens on both backends ($listed cases)"
