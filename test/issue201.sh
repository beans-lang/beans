#!/usr/bin/env bash
# #201: invalid bytes and digitless prefixes must fail in the lexer; a
# surplus generic close must stay visible after the parser splits `>>`.
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue201.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

reject() {
    local mode=$1 source=$2 expected=$3 status
    status=0
    "$compiler" "$mode" "$source" >"$tmp/diagnostics" 2>&1 || status=$?
    if [ "$status" -ne 1 ] || ! grep -Fq "$expected" "$tmp/diagnostics"; then
        echo "$mode $source: expected exit 1 and '$expected', got $status" >&2
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
for mode in parse ast check; do
    reject "$mode" "$tmp/extra.b" ":2:21: error: unexpected '>'"
    reject "$mode" "$tmp/nested-extra.b" ":2:31: error: unexpected '>'"
done

printf 'fn main() {\n    let x: int = 1 $ 2\n}\n' >"$tmp/stray.b"
for mode in lex parse ast check; do
    reject "$mode" "$tmp/stray.b" ":2:20: error: unexpected character '$'"
done
printf 'fn main() {\n    let x: int = 1\000\n}\n' >"$tmp/nul.b"
reject lex "$tmp/nul.b" ':2:19: error: unexpected byte 0'

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
