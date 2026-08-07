#!/usr/bin/env bash
# The semantic workspace, checked through `beansc sem-probe`.
#
# Every assertion here is about symbol *identity*, not about rendered text: two
# same-named methods on two same-named types in two packages must come back as
# two different symbols, a shadowed local must not answer for its shadow, and a
# completion must offer the receiver's own members and nothing else.
set -euo pipefail

cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
fixture=test/cases/semantic/main.b
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

probe() { "$bin" sem-probe "$1" "$2"; }

expect_line() { # <mode> <pos> <exact line that must appear>
    local got
    got=$(probe "$1" "$2")
    if ! grep -qxF -- "$3" <<<"$got"; then
        echo "FAIL $1 $2: expected line: $3" >&2
        echo "--- got ---" >&2; echo "$got" >&2
        exit 1
    fi
}

refuse_line() { # <mode> <pos> <line that must NOT appear>
    local got
    got=$(probe "$1" "$2")
    if grep -qxF -- "$3" <<<"$got"; then
        echo "FAIL $1 $2: line must not appear: $3" >&2
        echo "--- got ---" >&2; echo "$got" >&2
        exit 1
    fi
}

symbol_at() { probe symbol "$1" | sed -n 's/^symbol //p'; }

echo "checking semantic symbol identity"

# --- exact identity for declarations and uses ------------------------------
expect_line symbol "$fixture:8:11"  'symbol type:semfix::Drawable'
expect_line symbol "$fixture:8:11"  'kind interface'
expect_line symbol "$fixture:24:17" 'symbol fn:semfix::Circle.draw'
expect_line symbol "$fixture:24:17" 'kind method'
expect_line symbol "$fixture:10:8"  'symbol fn:semfix::Drawable.draw'

# --- two packages, one short type name -------------------------------------
# `a.size()` and `s.size()` are written the same way and mean different things.
expect_line symbol "$fixture:74:20" 'symbol fn:semfix.alpha::Shape.size'
expect_line symbol "$fixture:74:31" 'symbol fn:semfix.beta::Shape.size'
expect_line symbol "$fixture:74:42" 'symbol fn:semfix.beta::Shape.stretch'
expect_line symbol "$fixture:72:18" 'symbol type:semfix.alpha::Shape'
expect_line symbol "$fixture:73:15" 'symbol type:semfix.beta::Shape'
# ... and two same-named free functions reached through two import bindings
expect_line symbol "$fixture:75:24" 'symbol fn:semfix.alpha::scale'
expect_line symbol "$fixture:75:37" 'symbol fn:semfix.beta::scale'
expect_line symbol "$fixture:75:18" \
    "symbol import:$fixture#alpha"

# --- references never cross a same-named boundary --------------------------
refs_alpha=$(probe refs "$fixture:74:20")
grep -q '^symbol fn:semfix.alpha::Shape.size$' <<<"$refs_alpha" ||
    fail "alpha size refs resolved to the wrong symbol"
grep -q 'alpha/alpha.b:15:12+4 decl' <<<"$refs_alpha" ||
    fail "alpha size refs missing its declaration:
$refs_alpha"
if grep -q 'beta/beta.b' <<<"$refs_alpha"; then
    fail "alpha's size picked up beta's declaration:
$refs_alpha"
fi
refs_type=$(probe refs "$fixture:72:18")
grep -q 'alpha/alpha.b:6:11+5 decl' <<<"$refs_type" ||
    fail "alpha.Shape refs missing its declaration:
$refs_type"
if grep -q 'beta/beta.b' <<<"$refs_type"; then
    fail "alpha.Shape picked up beta.Shape:
$refs_type"
fi

# --- shadowed locals stay distinct -----------------------------------------
outer_id=$(symbol_at "$fixture:48:9")
inner_id=$(symbol_at "$fixture:51:13")
[ -n "$outer_id" ] || fail "the outer 'value' has no symbol"
[ "$outer_id" != "$inner_id" ] ||
    fail "a shadowed local shares its shadow's identity ($outer_id)"
outer=$(probe refs "$fixture:48:9")
inner=$(probe refs "$fixture:51:13")
[ "$(grep -c '^ref ' <<<"$outer")" = 2 ] ||
    fail "outer 'value' should have 2 references:
$outer"
[ "$(grep -c '^ref ' <<<"$inner")" = 2 ] ||
    fail "inner 'value' should have 2 references:
$inner"
grep -q 'main.b:49:22+5 read' <<<"$outer" ||
    fail "outer 'value' lost its use:
$outer"
grep -q 'main.b:52:25+5 read' <<<"$inner" ||
    fail "inner 'value' lost its use:
$inner"
if grep -q 'main.b:52:25' <<<"$outer"; then
    fail "the outer 'value' claimed the shadow's use:
$outer"
fi
if grep -q 'main.b:49:22' <<<"$inner"; then
    fail "the shadow claimed the outer 'value''s use:
$inner"
fi

# --- scopes decide what is visible -----------------------------------------
# Inside the if-block the shadow is what `value` means, and a local declared
# after the cursor is not in scope yet.
expect_line visible "$fixture:52:9" "visible local value $inner_id"
refuse_line visible "$fixture:52:9" "visible local value $outer_id"
inner_only_id=$(symbol_at "$fixture:54:9")
refuse_line visible "$fixture:52:9" "visible local inner_only $inner_only_id"
# After the block the outer binding is visible again.
expect_line visible "$fixture:55:5" "visible local value $outer_id"
expect_line visible "$fixture:55:5" "visible local inner_only $inner_only_id"
# A local of another function is never in scope here, but is in its own.
elsewhere_id=$(symbol_at "$fixture:59:9")
refuse_line visible "$fixture:55:5" "visible local elsewhere $elsewhere_id"
expect_line visible "$fixture:60:5" "visible local elsewhere $elsewhere_id"
# `self` is a binding of an instance method and of nothing else, and a type's
# members are reached through it rather than being in scope unqualified.
self_line=$(probe visible "$fixture:25:16" | grep '^visible parameter self ')
[ -n "$self_line" ] || fail "self should be visible inside an instance method"
refuse_line visible "$fixture:55:5" "$self_line"
refuse_line visible "$fixture:25:16" 'visible field radius field:semfix::Circle.radius'

# --- the checked hierarchy ------------------------------------------------
expect_line hierarchy "$fixture:17:7" 'sub type:semfix::Rounded'
expect_line hierarchy "$fixture:17:7" 'super type:semfix::Drawable'
impl=$(probe hierarchy "$fixture:8:11")
for want in Circle Square Rounded; do
    grep -q "^impl type:semfix::$want\$" <<<"$impl" ||
        fail "Drawable should be implemented by $want:
$impl"
done
# an override names the declaration it implements
expect_line hierarchy "$fixture:24:17" 'base fn:semfix::Drawable.draw'
# and the interface method names every implementation
draws=$(probe hierarchy "$fixture:10:8")
for want in Circle Square Rounded; do
    grep -q "^impl fn:semfix::$want.draw\$" <<<"$draws" ||
        fail "Drawable.draw should list $want.draw:
$draws"
done

# --- members come from the exact type --------------------------------------
members=$(probe members "$fixture:73:9")
grep -q '^member method stretch fn:semfix.beta::Shape.stretch$' <<<"$members" ||
    fail "beta.Shape should have stretch:
$members"
if grep -q 'semfix.alpha' <<<"$members"; then
    fail "beta.Shape listed alpha members:
$members"
fi

# --- whitespace resolves to nothing ----------------------------------------
if "$bin" sem-probe symbol "$fixture:47:1" >/dev/null 2>&1; then
    fail "an empty column should resolve to no symbol"
fi

echo "ok semantic identity: packages, shadowing, scopes, hierarchy, overrides"

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
echo "checking semantic completion"

cat >"$scratch/members.b" <<'BEANS'
package main
import std.io

class Alpha {
    a1: int
    fn only_alpha() -> int { return self.a1 }
}

class Beta {
    b1: int
    fn only_beta() -> int { return self.b1 }
}

fn other() -> int {
    let never_here: int = 1
    return never_here
}

fn main() {
    let x: Alpha = new Alpha(1)
    let y: Beta = new Beta(2)
    let text: string = "hi"
    let items: List<int> = [1, 2]
    x.
}
BEANS

complete() { "$bin" sem-probe complete "$1"; }

got=$(complete "$scratch/members.b:24:7")
grep -q '^item field a1 field:main::Alpha.a1$' <<<"$got" ||
    fail "x. should offer Alpha.a1:
$got"
grep -q '^item method only_alpha fn:main::Alpha.only_alpha$' <<<"$got" ||
    fail "x. should offer Alpha.only_alpha:
$got"
if grep -q 'Beta' <<<"$got"; then
    fail "x. offered members of another class:
$got"
fi
if grep -q 'never_here' <<<"$got"; then
    fail "x. offered a local from another function:
$got"
fi

# The same buffer with the receiver swapped: nothing from Alpha may appear.
sed 's/^    x\.$/    y./' "$scratch/members.b" >"$scratch/members_b.b"
got=$(complete "$scratch/members_b.b:24:7")
grep -q '^item method only_beta fn:main::Beta.only_beta$' <<<"$got" ||
    fail "y. should offer Beta.only_beta:
$got"
if grep -q 'Alpha' <<<"$got"; then
    fail "y. offered members of another class:
$got"
fi

# A built-in receiver answers from the checker's own registry.
sed 's/^    x\.$/    text./' "$scratch/members.b" >"$scratch/members_s.b"
got=$(complete "$scratch/members_s.b:24:10")
for want in len trim split to_int starts_with; do
    grep -q "^item method $want builtin:string.$want\$" <<<"$got" ||
        fail "text. should offer string.$want:
$got"
done
if grep -q 'builtin:List' <<<"$got"; then
    fail "a string receiver offered List members:
$got"
fi

sed 's/^    x\.$/    items./' "$scratch/members.b" >"$scratch/members_l.b"
got=$(complete "$scratch/members_l.b:24:11")
for want in push pop len sort; do
    grep -q "^item method $want builtin:List.$want\$" <<<"$got" ||
        fail "items. should offer List.$want:
$got"
done
if grep -q 'builtin:string' <<<"$got"; then
    fail "a List receiver offered string members:
$got"
fi

# A half-typed member filters by what is already written.
sed 's/^    x\.$/    x.only/' "$scratch/members.b" >"$scratch/members_p.b"
got=$(complete "$scratch/members_p.b:24:11")
grep -q '^item method only_alpha fn:main::Alpha.only_alpha$' <<<"$got" ||
    fail "x.only should still offer only_alpha:
$got"
if grep -q ' a1 ' <<<"$got"; then
    fail "x.only offered a member that does not start with 'only':
$got"
fi

# General completion at a cursor: locals in scope, not locals of elsewhere.
sed 's/^    x\.$/    let z: int = 0/' "$scratch/members.b" >"$scratch/general.b"
got=$(complete "$scratch/general.b:24:5")
grep -q '^item variable x ' <<<"$got" || fail "x should be visible:
$got"
grep -q '^item variable items ' <<<"$got" ||
    fail "items should be visible:
$got"
grep -q '^item class Alpha type:main::Alpha$' <<<"$got" ||
    fail "the package's own types should be visible:
$got"
grep -q '^item keyword return keyword:return$' <<<"$got" ||
    fail "keywords should be offered:
$got"
if grep -q '^item variable never_here ' <<<"$got"; then
    fail "a local of another function leaked into completion:
$got"
fi
if grep -q '^item variable z ' <<<"$got"; then
    fail "a local declared at the cursor is not in scope yet:
$got"
fi

# Cross-package completion through an import binding.
got=$(complete "$fixture:76:5")
grep -q '^item class Circle type:semfix::Circle$' <<<"$got" ||
    fail "the file's own package should be visible:
$got"
grep -q '^item module alpha ' <<<"$got" ||
    fail "an import binding should be offered:
$got"

echo "ok semantic completion: receiver members, builtins, scopes, prefixes"

# ---------------------------------------------------------------------------
# The built-in member table cannot drift from the checker
# ---------------------------------------------------------------------------
echo "checking the built-in member list covers the checker"
python3 - <<'PY'
import re, sys, pathlib

checker = pathlib.Path("compiler/beans/expression.b").read_text()
start = checker.index("fn builtin_method(receiver: HirType")
end = checker.index("fn builtin_static(type_name: string", start)
body = checker[start:end]
# only bare `name == "..."`, never `receiver.name == "..."`
wanted = set(re.findall(r'(?<!\.)\bname == "([a-z_0-9]+)"', body))

listing = pathlib.Path("compiler/beans/completion.b").read_text()
lstart = listing.index("fn semantic_builtin_member_names()")
lend = listing.index("fn semantic_render_builtin", lstart)
have = set(re.findall(r'"([a-z_0-9]+)"', listing[lstart:lend]))

missing = sorted(wanted - have)
if missing:
    print("FAIL: completion.b misses built-in members the checker accepts:",
          ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print(f"ok built-in member list: {len(wanted)} checker names all covered")
PY

# ---------------------------------------------------------------------------
# One snapshot serves many queries
# ---------------------------------------------------------------------------
echo "checking snapshot reuse"
builds=$(probe builds "$fixture:1:1" | sed -n 's/^builds //p')
[ "$builds" = 1 ] ||
    fail "nine snapshot requests at one revision should build once, built $builds"
echo "ok snapshot reuse: 9 requests, 1 check"
