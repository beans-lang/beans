#!/usr/bin/env bash
# A type name written inside a string's `{}` piece means what the same name
# means one character outside it (#164).
#
# The piece is lexed and parsed by the expression checker, long after the
# resolver walked the file, so nothing binds its type names for it. That
# binding used to be a second copy of the resolver's rule which never read
# the file's `import {A, B} from path` selections and, for a bare name,
# composed `<the asking package>.<name>` whether or not such a type existed.
# So `new T()`, `x as T`, `x as? T`, `f<T>(...)` and a closure parameter's
# type refused the program while naming a package nobody wrote, and
# `type_of(T)` was accepted and answered with a name find_type cannot find.
#
# One asking package cannot prove the rule: the composed name is right by
# accident whenever the type is declared in the asking package. So the
# fixture asks the same questions from a module root and from a named
# package beside it, about types that live in a third package reached only
# through a named import, and every answer is printed next to the answer the
# same words give outside the quotes.
set -euo pipefail

cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
root=$PWD
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-interp-types.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

good=test/cases/interp164_types_pkg/main.b
golden=test/cases/interp164_types_pkg/main.out

# --- the answers, on both backends -----------------------------------------
"$bin" run "$good" >"$tmp/interp"
diff -u "$golden" "$tmp/interp"
"$bin" build "$good" -o "$tmp/debug" >/dev/null
"$tmp/debug" >"$tmp/debug.out"
diff -u "$golden" "$tmp/debug.out"
"$bin" build --release "$good" -o "$tmp/release" >/dev/null
"$tmp/release" >"$tmp/release.out"
diff -u "$golden" "$tmp/release.out"

# The golden pins the exact names; these hold the claim even if someone
# regenerates it. Every row must agree, there must be rows from both asking
# packages, and the cross-package name must be the one that shows up — a
# regenerated golden full of `inside=interp164.Widget agree` would mean the
# fabricated name had won on both sides.
rows=$(grep -c ': inside=' "$tmp/interp" || true)
[ "$rows" -ge 60 ] || fail "only $rows rows compared; the battery shrank"
if grep -q 'DIFFER' "$tmp/interp"; then
    echo "--- rows that disagree ---" >&2
    grep 'DIFFER' "$tmp/interp" >&2
    fail "a type inside a string answered differently from the same type outside it"
fi
[ "$(grep -c '^main ' "$tmp/interp")" -ge 32 ] ||
    fail "the module root stopped asking"
[ "$(grep -c '^probe ' "$tmp/interp")" -ge 26 ] ||
    fail "the second named package stopped asking"
grep -Fq 'main type_of: inside=interp164.kit.Widget outside=interp164.kit.Widget' \
    "$tmp/interp" ||
    fail "type_of inside a string no longer answers the type's real package"
grep -Fq 'probe type_of: inside=interp164.kit.Widget outside=interp164.kit.Widget' \
    "$tmp/interp" ||
    fail "the second package's type_of no longer answers the real package"
grep -Fq 'main roundtrip: inside=true outside=true' "$tmp/interp" ||
    fail "find_type(type_of(T).qualified_name()) no longer finds the type"

# The three things the checker hands the resolver that no cross-package name
# can expose, because none of them is qualified by a package: the enclosing
# owner, the enclosing type parameters, and a builtin name. `Self` is the
# one that proves the scope is per-file rather than global -- the two askers
# must answer their own package and not each other's.
grep -Fq 'main Self: inside=interp164.Local outside=interp164.Local' \
    "$tmp/interp" ||
    fail "Self inside a string stopped meaning the module root's own class"
grep -Fq 'probe Self: inside=interp164.probe.Local outside=interp164.probe.Local' \
    "$tmp/interp" ||
    fail "Self inside a string stopped meaning the second package's own class"
grep -Fq 'main enclosing class type parameter: inside=interp164.kit.Widget' \
    "$tmp/interp" ||
    fail "a class type parameter named inside a string lost its binding"
grep -Fq 'main enclosing fn type parameter: inside=interp164.kit.Point' \
    "$tmp/interp" ||
    fail "a function type parameter named inside a string lost its binding"
grep -Fq 'main builtin widths: inside=13 outside=13' "$tmp/interp" ||
    fail "builtin type names inside a string stopped resolving"
if grep -Eq 'inside=interp164\.(Widget|Fancy|Point)' "$tmp/interp"; then
    echo "--- composed names ---" >&2
    grep -E 'inside=interp164\.(Widget|Fancy|Point)' "$tmp/interp" >&2
    fail "a type inside a string was named by gluing the asking package onto it"
fi
if grep -Eq 'inside=interp164\.probe\.(Widget|Fancy|Point)' "$tmp/interp"; then
    fail "the second package glued its own name onto an imported type"
fi

# --- a name nothing declares is refused, not composed -----------------------
bad=test/cases/interp164_types_pkg_bad/main.b
if "$bin" check "$bad" >"$tmp/bad" 2>&1; then
    echo "--- output ---" >&2; cat "$tmp/bad" >&2
    fail "$bad was accepted; an unresolvable type inside a string must be refused"
fi

expect_message() {
    grep -Fq "$1" "$tmp/bad" || {
        echo "--- output ---" >&2; cat "$tmp/bad" >&2
        fail "missing diagnostic: $1"
    }
}

# Each of these is the message the same spelling gets outside the quotes.
expect_message ":13:30: error: unknown type 'Nope'"
expect_message ":14:30: error: 'helper' is a function, not a type"
expect_message ":15:30: error: 'SIZE' is a constant, not a type"
expect_message ":16:30: error: type 'kit.Hidden' isn't pub in package 'interp164bad.kit'"
expect_message ":17:30: error: Self needs an enclosing class or interface"
expect_message ":18:26: error: unknown type 'Nope'"
expect_message ":19:29: error: unknown type 'Nope'"
expect_message ":20:30: error: unknown type 'Nope'"

# The fingerprint of the bug: a package name invented by gluing the asking
# package onto the simple name. `interp164bad.Nope` and `interp164bad.Self`
# name nothing and were never written; no diagnostic may say them.
if grep -Eq "interp164bad\.(Nope|Self|helper|SIZE)\b" "$tmp/bad"; then
    echo "--- output ---" >&2; cat "$tmp/bad" >&2
    fail "a diagnostic named a type composed from the asking package"
fi

# --- the editor answers the same symbol on both sides of the quote ---------
# The LSP reads the very nodes the checker bound, so a type inside a piece
# that the checker mis-bound is a type an editor cannot navigate. Positions
# are computed from the fixture rather than pinned, so editing it cannot
# quietly move the probe off the name it is about.
column_of() { # <file> <line-substring> <needle>
    awk -v pat="$2" -v needle="$3" '
        index($0, pat) && !done { i = index($0, needle)
                                  if (i) { print NR ":" i; done = 1 } }
    ' "$1"
}

symbol_at() { "$bin" sem-probe symbol "$1" | sed -n 's/^symbol //p'; }

lsp_file=$root/test/cases/interp164_types_pkg/main.b
probe_file=$root/test/cases/interp164_types_pkg/probe/probe.b
inside=$(column_of "$lsp_file" '"{type_of(Widget).qualified_name()}"' 'Widget')
outside=$(column_of "$lsp_file" 'let widget_outside: reflect.Type' 'Widget')
[ -n "$inside" ] && [ -n "$outside" ] ||
    fail "the fixture no longer holds the two positions this probes"
inside_id=$(symbol_at "$lsp_file:$inside")
outside_id=$(symbol_at "$lsp_file:$outside")
[ "$outside_id" = "type:interp164.kit::Widget" ] ||
    fail "outside the quotes the editor answered '$outside_id'"
[ "$inside_id" = "$outside_id" ] ||
    fail "inside the quotes the editor answered '$inside_id', outside '$outside_id'"
"$bin" sem-probe refs "$lsp_file:$inside" >"$tmp/refs"
grep -q 'kit/kit\.b:.*decl' "$tmp/refs" ||
    { cat "$tmp/refs" >&2
      fail "go-to-definition from inside a string reaches no declaration"; }

probe_inside=$(column_of "$probe_file" '"{type_of(Widget).qualified_name()}"' 'Widget')
[ -n "$probe_inside" ] || fail "the probe fixture lost its position"
probe_id=$(symbol_at "$probe_file:$probe_inside")
[ "$probe_id" = "type:interp164.kit::Widget" ] ||
    fail "in the second package the editor answered '$probe_id' inside a string"

echo "ok interpolated types: a type inside a string binds through the file's imports, on both backends and in the editor"
