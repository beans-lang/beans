#!/usr/bin/env bash
# #206: enforce the existing else-line contract and pin settled spec probes.
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue206.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

reject_else() {
    local name=$1 line=$2 col=$3 mode status
    for mode in parse ast check run; do
        status=0
        "$compiler" "$mode" "$tmp/$name.b" >"$tmp/$name.$mode" 2>&1 || status=$?
        if [ "$status" -ne 1 ] ||
           ! grep -Fq ":$line:$col: error: else must follow '}' on the same line" "$tmp/$name.$mode" ||
           [ "$(grep -c ': error: ' "$tmp/$name.$mode")" -ne 1 ]; then
            echo "$name/$mode: expected one located else-line error and exit 1, got $status" >&2
            cat "$tmp/$name.$mode" >&2
            exit 1
        fi
        if [ "$mode" = ast ] && ! grep -Fq '(let "kept"' "$tmp/$name.$mode"; then
            echo "$name: following declaration was lost during recovery" >&2
            cat "$tmp/$name.$mode" >&2
            exit 1
        fi
    done
}

cat >"$tmp/statement.b" <<'BEANS'
fn main() {
    if true {
    }
    else {
    }
    let kept: int = 7
}
BEANS
reject_else statement 4 5

cat >"$tmp/value.b" <<'BEANS'
fn main() {
    let x: int = if true { 1 }
    else { 2 }
    let kept: int = 7
}
BEANS
reject_else value 3 5

cat >"$tmp/chain.b" <<'BEANS'
fn main() {
    if true { }
    else if false { } else { }
    let kept: int = 7
}
BEANS
reject_else chain 3 5

cat >"$tmp/value-chain.b" <<'BEANS'
fn main() {
    let x: int = if true { 1 }
    else if false { 2 } else { 3 }
    let kept: int = 7
}
BEANS
reject_else value-chain 3 5

cat >"$tmp/comment.b" <<'BEANS'
fn main() {
    if true { } /* newline inside a comment
    */ else { }
    let kept: int = 7
}
BEANS
reject_else comment 3 8

cat >"$tmp/value-comment.b" <<'BEANS'
fn main() {
    let x: int = if true { 1 } /* newline inside a comment
    */ else { 2 }
    let kept: int = 7
}
BEANS
reject_else value-comment 3 8

# CRLF still records the actual else token's line.
sed 's/$/\r/' "$tmp/statement.b" >"$tmp/crlf.b"
reject_else crlf 4 5

cat >"$tmp/issue206-valid-policy.b" <<'BEANS'
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
    io.println("[{v:}]")
    io.println("[{v}]")
    io.println(continued)
    io.println(1 == 1 == true)
    io.println(6 & 3 == 2)
    if (false) { io.println("wrong") } else if (true) {
        io.println("chain")
    } else { io.println("wrong") }
    let selected: int = if false { 0 } else if true { 1 } else { 2 }
    io.println(selected)
    if false { } /* same line */ else { io.println("comment") }
    if false { } else
    { io.println("brace") }
}
BEANS
cat >"$tmp/valid.expected" <<'OUT'
10
1
15
0
7
4
0
[7]
[7]
3
true
true
chain
1
comment
brace
OUT
for mode in lex parse ast check; do
    "$compiler" "$mode" "$tmp/issue206-valid-policy.b" >"$tmp/valid.$mode"
done
"$compiler" run "$tmp/issue206-valid-policy.b" >"$tmp/valid.interp"
diff -u "$tmp/valid.expected" "$tmp/valid.interp"
"$compiler" build "$tmp/issue206-valid-policy.b" -o "$tmp/valid.native" >/dev/null
"$tmp/valid.native" >"$tmp/valid.native.out"
diff -u "$tmp/valid.expected" "$tmp/valid.native.out"

echo 'ok #206: located else-line refusals, comment/CRLF recovery and settled syntax probe parity'
