#!/usr/bin/env bash
# The interpreter and the native backend must answer the same bytes for the
# same program, and must do the same amount of work getting there.
#
# Four shipped bugs were exactly this disagreement and none were visible to a
# test that ran only one side:
#
#   * an empty struct literal in field-default position, where the struct it
#     builds is declared in a later-sorting file of the same package
#   * `%` between floats, which the checker accepted and the interpreter
#     refused
#   * a Map whose value is move-only, read through get(key)
#   * a class -> interface upcast at a `return`, which the interpreter took
#     and the native backend refused
#   * a class extending a generic base, whose release the native backend
#     either called through a null pointer or never called at all
#   * sorting a list of inline records, which the native backend refused
#     because sort only ever handled slot-wide elements
#   * `List<T> ==` and `List<T>.is_empty()`, refused natively while the
#     interpreter answered both
#   * `Option<T> ==` where T is a reference, which the native backend
#     answered by address — a wrong answer rather than a refusal
#
# Each case runs on the interpreter, a debug build and a release build, and
# all three have to match. There is no golden output on purpose: the claim is
# that the backends agree, not that any one prints a chosen string.
#
# Diffing answers is not enough on its own. A fix for the first bug above was
# once written twice — checker and interpreter — and every struct default then
# ran twice. The field values were identical either way, so a gate that only
# compared printed answers saw nothing; the sole trace was an extra construct
# and an extra release per field. So the cases print `arc+tag` when a
# value is built and `arc-tag` when it is released, and this gate checks:
#
#   * the markers balance — the same tags on both sides, so nothing leaked
#     and nothing was released twice
#   * the total matches a pinned count, so a change that runs something twice
#     on BOTH backends still fails, which a backend-to-backend diff cannot see
#
# Answers catch wrong results. Markers catch wrong evaluation count, order and
# lifetime. A case that carries no markers only gets the first.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-parity.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# The marker prefix is `arc+` / `arc-` rather than a bare sign: a case that
# prints a negative number would otherwise read as a release.
#
# effects <file> <sign> — how many marker lines of one kind the run printed
effects() {
    grep -c "^arc$2" "$1" 2>/dev/null || true
}

# tags <file> <sign> — the marker tags of one kind, sorted
tags() {
    grep "^arc$2" "$1" 2>/dev/null | cut -c5- | sort || true
}

# check_effects <file> <source> <expected-constructs>
# An empty expectation means the case carries no markers; the balance check
# then holds trivially and only the answers are being compared.
check_effects() {
    local file=$1 source=$2 want=$3 built dropped
    built=$(effects "$file" '+')
    dropped=$(effects "$file" '-')
    if [ "$built" != "$dropped" ]; then
        echo "$source: built $built values but released $dropped" >&2
        echo "a value leaked or was released twice" >&2
        exit 1
    fi
    if ! diff -u <(tags "$file" '+') <(tags "$file" '-') >"$tmp/tagdiff"; then
        echo "$source: the tags built and the tags released differ" >&2
        cat "$tmp/tagdiff" >&2
        exit 1
    fi
    if [ -n "$want" ] && [ "$built" != "$want" ]; then
        echo "$source: built $built values, expected $want" >&2
        echo "something now runs a different number of times" >&2
        grep '^arc[+-]' "$file" >&2 || true
        exit 1
    fi
}

# agree <source> [expected-constructs]
agree() {
    local source=$1 want=${2:-} name
    name=$(basename "$source" .b)
    ./build/beansc run "$source" >"$tmp/$name.interp"
    ./build/beansc build "$source" -o "$tmp/$name.debug" >/dev/null
    "$tmp/$name.debug" >"$tmp/$name.debug.out"
    ./build/beansc build --release "$source" -o "$tmp/$name.release" >/dev/null
    "$tmp/$name.release" >"$tmp/$name.release.out"
    if ! diff -u "$tmp/$name.interp" "$tmp/$name.debug.out"; then
        echo "$source: the interpreter and a debug build disagree" >&2
        exit 1
    fi
    if ! diff -u "$tmp/$name.interp" "$tmp/$name.release.out"; then
        echo "$source: the interpreter and a release build disagree" >&2
        exit 1
    fi
    # a program that prints nothing would pass the diffs above without
    # having proved anything
    if [ ! -s "$tmp/$name.interp" ]; then
        echo "$source printed nothing" >&2
        exit 1
    fi
    check_effects "$tmp/$name.interp" "$source" "$want"
    local note=""
    [ -n "$want" ] && note=", $want built and released"
    echo "  agree: $source ($(wc -l <"$tmp/$name.interp" | tr -d ' ') lines$note)"
}

echo "checking the two backends answer alike and work alike"
agree test/cases/parity/float_remainder.b
agree test/cases/parity/map_move_only_get.b
agree test/cases/parity/default_effects.b 5
agree test/cases/parity/interface_upcast.b 6
agree test/cases/parity/generic_base_deinit.b 4
agree test/cases/parity/struct_sort.b 3
agree test/cases/parity/list_equality.b
agree test/cases/parity/option_equality.b
agree test/cases/parity/cast_compare.b

# Every case in the directory has to be listed above with its own expected
# count; a file added and forgotten would otherwise be silently unchecked.
listed=9
present=$(find test/cases/parity -name '*.b' | wc -l | tr -d ' ')
if [ "$present" != "$listed" ]; then
    echo "test/cases/parity holds $present cases but $listed are run" >&2
    echo "add the new case to backend_parity.sh with its expected count" >&2
    exit 1
fi

# The cross-file default needs a real package, so it is its own tree and is
# run from inside it the way a user's project would be. Running from there
# loses the repo-relative source roots, so they are pinned first — the same
# thing the Makefile does when it bootstraps against this tree.
root=$(pwd -P)
export BEANS_RUNTIME="$root/runtime/beans_rt.c"
export BEANS_STDLIB="$root/stdlib/std"
export BEANS_ENCODING="$root/runtime/encoding"
export BEANS_NET="$root/runtime/net"
export BEANS_LOG="$root/runtime/log"
name=parity_defaults
( cd "test/cases/$name" && "$root/build/beansc" run tests/main.b ) \
    >"$tmp/$name.interp"
( cd "test/cases/$name" \
  && "$root/build/beansc" build --release tests/main.b \
       -o "$tmp/$name.release" >/dev/null )
"$tmp/$name.release" >"$tmp/$name.release.out"
diff -u "$tmp/$name.interp" "$tmp/$name.release.out"
grep -q "solid 0 1 2" "$tmp/$name.interp" || {
    echo "cross-file struct defaults were not applied" >&2
    cat "$tmp/$name.interp" >&2
    exit 1
}
check_effects "$tmp/$name.interp" "test/cases/$name" ""
echo "  agree: test/cases/$name (cross-file struct defaults)"

# The forms that must stay refused, with the message that names the way out.
cat >"$tmp/bad.b" <<'EOF'
package main
fn main() {
    var m: Map<string, List<int>> = {}
    m["a"] = [1, 2, 3]
    let taken: List<int> = m["a"]
}
EOF
if ./build/beansc check "$tmp/bad.b" >"$tmp/bad.out" 2>&1; then
    echo "indexing a move-only map value was accepted" >&2
    exit 1
fi
grep -Fq "read it with get(key)" "$tmp/bad.out" || {
    echo "the index refusal no longer names get(key)" >&2
    cat "$tmp/bad.out" >&2
    exit 1
}
echo "  refused: indexing a move-only map value, both directions"

echo "ok backend parity: answers, construct and release counts, refusals"
