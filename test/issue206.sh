#!/usr/bin/env bash
# #206: the settled spec probes (spec/SYNTAX.md, Lexical, Strings, Generics,
# match), each pinned by what the compiler prints and its exit status.
#
# `else` may begin the line after `}`: no statement starts with `else`, so
# the layout is unambiguous, and the sibling packages and older programs
# are written that way. `} else {` stays the house style.
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue206.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Same output from the interpreter and a native build, after a clean check.
run_both() {
    local name=$1 mode
    for mode in lex parse ast check; do
        if ! "$compiler" "$mode" "$tmp/$name.b" >"$tmp/$name.$mode" 2>&1; then
            echo "$name: 'beansc $mode' refused a valid program" >&2
            cat "$tmp/$name.$mode" >&2
            exit 1
        fi
    done
    "$compiler" run "$tmp/$name.b" >"$tmp/$name.interp"
    diff -u "$tmp/$name.expected" "$tmp/$name.interp"
    "$compiler" build "$tmp/$name.b" -o "$tmp/$name.native" >/dev/null
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "$tmp/$name.expected" "$tmp/$name.native.out"
}

# Exactly one error, at the given place, with the given text, and exit 1.
reject_once() {
    local name=$1 mode=$2 where=$3 message=$4 status=0
    "$compiler" "$mode" "$tmp/$name.b" >"$tmp/$name.$mode" 2>&1 || status=$?
    if [ "$status" -ne 1 ] ||
       ! grep -Fq "$name.b:$where: error: $message" "$tmp/$name.$mode" ||
       [ "$(grep -c ': error: ' "$tmp/$name.$mode")" -ne 1 ]; then
        echo "$name/$mode: expected one '$message' at $where and exit 1, got $status" >&2
        cat "$tmp/$name.$mode" >&2
        exit 1
    fi
}

cat >"$tmp/else_layout.b" <<'BEANS'
import std.io

fn main() {
    if false {
        io.println("wrong")
    }
    else {
        io.println("statement")
    }
    if false { io.println("wrong") }
    else if true { io.println("chain") }
    else { io.println("wrong") }
    let value: int = if false { 1 }
        else if false { 2 }
        else { 3 }
    io.println(value)
    if false { } /* a comment that
    spans lines */ else { io.println("comment") }
    if false { } else
    { io.println("brace") }
}
BEANS
cat >"$tmp/else_layout.expected" <<'OUT'
statement
chain
3
comment
brace
OUT
run_both else_layout
# CRLF line ends are the same layout.
sed 's/$/\r/' "$tmp/else_layout.b" >"$tmp/else_crlf.b"
cp "$tmp/else_layout.expected" "$tmp/else_crlf.expected"
run_both else_crlf

# A dangling `else` with no `if` before it is still one located error.
printf 'fn main() {\n    let x: int = 1\n    else { }\n    let kept: int = x\n}\n' >"$tmp/else_dangling.b"
reject_once else_dangling check 3:5 'expected expression'

cat >"$tmp/policy.b" <<'BEANS'
import std.io

fn id<T>(v: T) -> T { return v }
fn empty<>() -> int { return 4 }

fn main() {
    let doubled: int = 1__0
    let trailing: int = 1_
    let prefixed: int = 0x_F
    let values: Map<int, int,> = {}
    let matched: int = match 2 {
        1 => 10
        _ => 0
    }
    let inline: Option<int> = some(5)
    let unwrapped: int = match inline { some(v) => v none => 0 }
    let v: int = 7
    let continued: int = (1 +
        2)
    io.println(doubled)
    io.println(trailing)
    io.println(prefixed)
    io.println(values.len())
    io.println(id<int,>(7))
    io.println(empty())
    io.println(matched)
    io.println(unwrapped)
    io.println("[{v:}]")
    io.println("[{v}]")
    io.println(continued)
    io.println(1 == 1 == true)
    io.println(6 & 3 == 2)
    if (false) { io.println("wrong") } else if (true) {
        io.println("parenthesized")
    }
}
BEANS
cat >"$tmp/policy.expected" <<'OUT'
10
1
15
0
7
4
0
5
[7]
[7]
3
true
true
parenthesized
OUT
run_both policy

# The refusals the spec now states, each as one located error.
printf 'fn main() {\n    let x: int = (1\n        + 2)\n}\n' >"$tmp/paren_newline.b"
"$compiler" check "$tmp/paren_newline.b" >"$tmp/paren_newline.check" 2>&1 && {
    echo "(1 newline + 2) was accepted" >&2; exit 1; }
grep -Fq "paren_newline.b:2:20: error: expected ')'" "$tmp/paren_newline.check" || {
    echo "(1 newline + 2): the primary error should sit where the newline ended (1" >&2
    cat "$tmp/paren_newline.check" >&2; exit 1; }
printf 'fn main() {\n    let x: float = 1e1_0\n}\n' >"$tmp/exponent_separator.b"
reject_once exponent_separator check 2:23 'expected end of statement'
printf '\357\273\277fn main() {\n}\n' >"$tmp/bom.b"
for mode in lex parse check; do
    reject_once bom "$mode" 1:1 'unexpected byte-order mark (U+FEFF)'
done
printf 'fn id<T>(v: T) -> T { return v }\nfn main() {\n    let x: int = id<>(3)\n}\n' >"$tmp/empty_args.b"
reject_once empty_args parse 3:20 "expected a type argument after '<'"

echo 'ok #206: else after a newline, settled syntax probes and their refusals, interpreter/native parity'
