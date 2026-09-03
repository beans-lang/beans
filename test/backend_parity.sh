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
#   * an interface default reached through a super-interface, which the
#     INTERPRETER got wrong while the native backend was right
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
agree test/cases/parity/sort_by_key_paths.b
agree test/cases/parity/list_equality.b
agree test/cases/parity/option_equality.b
agree test/cases/parity/cast_compare.b
agree test/cases/parity/option_layout.b
agree test/cases/parity/composite_equality.b
agree test/cases/parity/inherited_defaults.b
agree test/cases/parity/static_fn_field.b
agree test/cases/parity/panic_diverges.b
agree test/cases/parity/super_in_scope.b
agree test/cases/parity/discard_binding.b 7
agree test/cases/parity/record_place.b 3
agree test/cases/parity/bind_release.b 111
agree test/cases/parity/scope_exit_order.b 14
agree test/cases/parity/sort_panic_state.b
agree test/cases/parity/map_replace_panic.b
agree test/cases/parity/assign_eval_order.b
# `?` crossing an error boundary: the source error is converted through
# to_error or widened to a supertype, and both backends have to do it once —
# for a call operand, a local operand, a bare statement `f()?`, and each hop
# of a nested `f()??`. The six source errors are the pinned construct count.
agree test/cases/parity/error_conversion.b 6
# std failing its own users — a std.reflect failure crossing into a plain
# Result<T> through ReflectError.to_error, on both the ok and err paths.
agree test/cases/parity/reflect_error_bridge.b

# Every case in the directory has to be listed above with its own expected
# count; a file added and forgotten would otherwise be silently unchecked.
listed=25
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

# `super.init(...)` ownership needs a library package: constructing from the
# same package takes a different path and never showed the fault.
name=parity_super
( cd "test/cases/$name" && "$root/build/beansc" run tests/main.b ) \
    >"$tmp/$name.interp"
( cd "test/cases/$name" \
  && "$root/build/beansc" build --release tests/main.b \
       -o "$tmp/$name.release" >/dev/null )
"$tmp/$name.release" >"$tmp/$name.release.out"
diff -u "$tmp/$name.interp" "$tmp/$name.release.out"
grep -q "tags 12 atlas atlas" "$tmp/$name.interp" || {
    echo "the super-init field did not survive" >&2
    cat "$tmp/$name.interp" >&2
    exit 1
}
echo "  agree: test/cases/$name (super.init argument ownership)"

# Static fields initialise before main, in file order. The forward case is
# ordinary; the backward one — reading a static whose initialiser has not run
# yet — used to answer the zero it was born with in a native build while the
# interpreter panicked.
name=parity_statics
( cd "test/cases/$name" && "$root/build/beansc" run main.b ) \
    >"$tmp/$name.interp"
( cd "test/cases/$name" \
  && "$root/build/beansc" build --release main.b \
       -o "$tmp/$name.release" >/dev/null )
"$tmp/$name.release" >"$tmp/$name.release.out"
diff -u "$tmp/$name.interp" "$tmp/$name.release.out"
grep -q "built 3" "$tmp/$name.interp" || {
    echo "static table entries were not built exactly once" >&2
    cat "$tmp/$name.interp" >&2
    exit 1
}
echo "  agree: test/cases/$name (static tables build once, before main)"

# Reading one too early has to say so on both paths, not answer a zero on one.
mkdir -p "$tmp/early"
printf 'module early\nkind application\n' >"$tmp/early/beans.pot"
cat >"$tmp/early/aa_reader.b" <<'EOF'
package main
class Reader {
    static tripled: int = Seed.value * 3
}
EOF
cat >"$tmp/early/zz_seed.b" <<'EOF'
package main
class Seed {
    static value: int = 5
}
EOF
cat >"$tmp/early/main.b" <<'EOF'
package main
import std.io
fn main() {
    io.println("{Reader.tripled}")
}
EOF
( cd "$tmp/early" && "$root/build/beansc" run main.b ) \
    >"$tmp/early.interp" 2>&1 || true
( cd "$tmp/early" \
  && "$root/build/beansc" build --release main.b \
       -o "$tmp/early.bin" >/dev/null )
"$tmp/early.bin" >"$tmp/early.native" 2>&1 || true
if ! diff -u "$tmp/early.interp" "$tmp/early.native"; then
    echo "reading a static before its initialiser ran differs between backends" >&2
    exit 1
fi
grep -Fq "was read before initialization" "$tmp/early.interp" || {
    echo "reading a static too early no longer reports it" >&2
    cat "$tmp/early.interp" >&2
    exit 1
}
echo "  refused: reading a static before its initialiser ran, both backends"

# A move-only map value is not symmetric between the two bracket forms. The
# write moves a value in — the same transfer m.set(k, v) does — and is
# accepted; the read would have to copy the map's own value and stays refused
# with the message that names the way out. The two are checked in separate
# files on purpose: proving the write is accepted needs a file that does not
# also fail for the read.
cat >"$tmp/write_ok.b" <<'EOF'
package main
fn main() {
    var m: Map<string, List<int>> = {}
    m["a"] = [1, 2, 3]
}
EOF
./build/beansc check "$tmp/write_ok.b" >"$tmp/write_ok.out" 2>&1 || {
    echo "moving a value into a move-only map by bracket was refused" >&2
    cat "$tmp/write_ok.out" >&2
    exit 1
}
cat >"$tmp/read_bad.b" <<'EOF'
package main
fn main() {
    var m: Map<string, List<int>> = {}
    m["a"] = [1, 2, 3]
    let taken: List<int> = m["a"]
}
EOF
if ./build/beansc check "$tmp/read_bad.b" >"$tmp/read_bad.out" 2>&1; then
    echo "reading a move-only map value by index was accepted" >&2
    exit 1
fi
grep -Fq "read it with get(key)" "$tmp/read_bad.out" || {
    echo "the index read refusal no longer names get(key)" >&2
    cat "$tmp/read_bad.out" >&2
    exit 1
}
echo "  refused: reading a move-only map value by index; the write moves in"

# A map has no equality. The interpreter used to answer false for every pair,
# including a map against itself, while a native build refused to emit it.
cat >"$tmp/mapeq.b" <<'EOF'
package main
fn main() {
    var left: Map<string, int> = {}
    var right: Map<string, int> = {}
    let same: bool = left == right
}
EOF
if ./build/beansc check "$tmp/mapeq.b" >"$tmp/mapeq.out" 2>&1; then
    echo "comparing two maps was accepted" >&2
    exit 1
fi
grep -Fq "is not defined for Map<string, int>" "$tmp/mapeq.out" || {
    echo "the map refusal no longer names the type" >&2
    cat "$tmp/mapeq.out" >&2
    exit 1
}
echo "  refused: comparing two maps, in the caller's own terms"

# A defer is a function-exit hook (spec/SYNTAX.md): registered inside a
# nested block it would run after the block's locals dropped — the native
# run-site read a released cell and crashed on any owned capture. The
# checker refuses the shape; the primitive-capture case that happened to
# work is refused with it.
cat >"$tmp/nesteddefer.b" <<'EOF'
package main
import std.io

fn late_words(deep: bool) {
    if deep {
        let held: string = "kept {deep}"
        defer io.println("late {held}")
        io.println("body")
    }
}

fn main() {
    late_words(true)
}
EOF
if ./build/beansc check "$tmp/nesteddefer.b" >"$tmp/nesteddefer.out" 2>&1; then
    echo "a defer inside a nested block was accepted" >&2
    exit 1
fi
grep -Fq "defer at the function's own scope" "$tmp/nesteddefer.out" || {
    echo "the nested-defer refusal no longer names the way out" >&2
    cat "$tmp/nesteddefer.out" >&2
    exit 1
}
echo "  refused: a defer inside a nested block, both backends"

echo "ok backend parity: answers, construct and release counts, refusals"
