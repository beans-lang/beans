#!/usr/bin/env bash
# #201: invalid bytes and digitless prefixes fail in the lexer, and a surplus
# generic close is one error where its type ends. Each refusal is exactly one
# located error with exit 1; the valid forms (nested closes, shifts) run the
# same under the interpreter and a native build.
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue201.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

reject() {
    local mode=$1 source=$2 expected=$3 status
    status=0
    "$compiler" "$mode" "$source" >"$tmp/diagnostics" 2>&1 || status=$?
    if [ "$status" -ne 1 ] || ! grep -Fq "$expected" "$tmp/diagnostics" ||
       [ "$(grep -c ': error: ' "$tmp/diagnostics")" -ne 1 ]; then
        echo "$mode $source: expected exit 1 and only '$expected', got $status" >&2
        cat "$tmp/diagnostics" >&2
        exit 1
    fi
}

for literal in 0x 0X 0x_ 0X___ 0b 0B 0b_ 0B___; do
    printf 'fn main() {\n    let x: int = %s\n}\n' "$literal" >"$tmp/digits.b"
    case "$literal" in
        0x*|0X*) reason='hex literal needs at least one digit' ;;
        *) reason='binary literal needs at least one digit' ;;
    esac
    for mode in lex parse ast check; do
        reject "$mode" "$tmp/digits.b" ":2:18: error: $reason"
    done
done

printf 'fn main() {\n    let x: List<int>> = []\n}\n' >"$tmp/extra.b"
printf 'fn main() {\n    let x: Map<int, List<int>>> = {}\n}\n' >"$tmp/nested-extra.b"
# The same stray close in a signature, a field and a function type: one
# error where the type ends, not what the declaration expected next.
printf 'fn f() -> List<int>> {\n    return []\n}\nfn main() {}\n' >"$tmp/result-extra.b"
printf 'fn f(xs: List<int>>) {\n}\nfn main() {}\n' >"$tmp/param-extra.b"
printf 'struct S {\n    xs: List<int>>\n    y: int\n}\nfn main() {}\n' >"$tmp/field-extra.b"
printf 'fn main() {\n    let f: fn(List<int>>) -> int = g\n}\n' >"$tmp/fn-type-extra.b"
for mode in parse ast check; do
    reject "$mode" "$tmp/extra.b" ":2:21: error: unexpected '>'"
    reject "$mode" "$tmp/nested-extra.b" ":2:31: error: unexpected '>'"
    reject "$mode" "$tmp/result-extra.b" ":1:20: error: unexpected '>'"
    reject "$mode" "$tmp/param-extra.b" ":1:19: error: unexpected '>'"
    reject "$mode" "$tmp/field-extra.b" ":2:18: error: unexpected '>'"
    reject "$mode" "$tmp/fn-type-extra.b" ":2:24: error: unexpected '>'"
done

# #214: the type closer was swallowed into >=; point to the missing space.
printf 'fn main() {\n    let xs: List<int>= [3]\n}\n' >"$tmp/close-equal.b"
for mode in parse ast check; do
    reject "$mode" "$tmp/close-equal.b" ":2:21: error: write a space between '>' and '='"
done

printf 'fn main() {\n    let x: int = 1 $ 2\n}\n' >"$tmp/stray.b"
for mode in lex parse ast check; do
    reject "$mode" "$tmp/stray.b" ":2:20: error: unexpected character '$'"
done
printf 'fn main() {\n    let x: int = 1\000\n}\n' >"$tmp/nul.b"
reject lex "$tmp/nul.b" ':2:19: error: unexpected byte 0x00'
# A UTF-8 character outside a string is one error that names it.
printf 'fn main() {\n    let caf\303\251: int = 1\n}\n' >"$tmp/utf8.b"
reject check "$tmp/utf8.b" ":2:12: error: unexpected character '$(printf '\303\251')' (U+00E9)"

cat >"$tmp/issue201-valid.b" <<'BEANS'
import std.io

fn main() {
    let hex: int = 0x_F_F_
    let bits: int = 0B_1_0_1_
    let xs: List<List<int>>=[[3]]
    let values: Map<int, List<int>> = {}
    let nested: Option<Option<Option<int>>> = some(some(some(7)))
    io.println("{hex} {bits} {xs[0][0]} {values.len()} {8 >> 1} {1 << 3} {(3 as int) > 2}")
}
BEANS
printf '255 5 3 0 4 8 true\n' >"$tmp/valid.expected"
for mode in lex parse ast check; do
    "$compiler" "$mode" "$tmp/issue201-valid.b" >"$tmp/valid.$mode"
done
"$compiler" run "$tmp/issue201-valid.b" >"$tmp/valid.interp"
diff -u "$tmp/valid.expected" "$tmp/valid.interp"
"$compiler" build "$tmp/issue201-valid.b" -o "$tmp/valid.native" >/dev/null
"$tmp/valid.native" >"$tmp/valid.native.out"
diff -u "$tmp/valid.expected" "$tmp/valid.native.out"

# Reuse the owning regressions for nested explicit call arguments and
# bounds ending in `>>`, rather than inventing a second generic corpus.
for name in generic_calls_ok generic_interfaces_ok; do
    "$compiler" run "test/cases/$name.b" >"$tmp/$name.out"
    diff -u "test/cases/$name.out" "$tmp/$name.out"
done

echo 'ok #201: located lexical errors, surplus generic closes, nested calls/bounds and shift parity'
