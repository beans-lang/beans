#!/usr/bin/env bash
# #205: a diagnostic keeps its one-line `file:line:col: error: message` head
# and exit status, and adds context under it: the source line, a caret under
# the primary column, and ordered notes ('(' opened at, in function …
# declared at, generic parameter … declared at, imported at). The LSP half
# (relatedInformation for unsaved documents) is in test/lsp_navigation.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-./build/beansc}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/$compiler" ;;
esac
python3=${PYTHON3:-python3}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-diagnostic-context.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# The authored context-chain targets: exact stdout and stderr for an
# unclosed paren, a brace missing at EOF, a parse error inside a string
# piece, a generic binding conflict and an unknown name in an imported
# file, plus every missing-delimiter case. Each compares the whole output,
# so a derivative error or a lost note fails here.
args=()
for name in diagnostic_missing_paren diagnostic_eof diagnostic_interpolation \
    diagnostic_generic_binding diagnostic_cross_file \
    delimiter_missing_paren delimiter_missing_bracket \
    delimiter_missing_map_brace delimiter_missing_call_paren \
    delimiter_missing_generic_close; do
    args+=(--case "$name")
done
"$python3" -B tools/syntax_fuzz.py --beansc "$compiler" --ignore-baseline \
    --out "$tmp/discovery" ${args+"${args[@]}"} >"$tmp/discovery.log" 2>&1 || {
    cat "$tmp/discovery.log" >&2
    exit 1
}

# Run one mode on $tmp/NAME/main.b from inside that directory, so paths
# print as `main.b`, and require exit 1 and exactly $tmp/NAME.MODE.expected
# on stderr.
expect_stderr() {
    local name=$1 mode=$2 status=0
    (cd "$tmp/$name" && "$compiler" "$mode" main.b) \
        >"$tmp/$name.$mode.stdout" 2>"$tmp/$name.$mode.stderr" || status=$?
    if [ "$status" -ne 1 ]; then
        echo "$name/$mode: expected exit 1, got $status" >&2
        cat "$tmp/$name.$mode.stderr" >&2
        exit 1
    fi
    if ! diff -u "$tmp/$name.$mode.expected" "$tmp/$name.$mode.stderr" >&2; then
        echo "$name/$mode: context output differs (expected first)" >&2
        exit 1
    fi
}

case_dir() { mkdir -p "$tmp/$1"; }

# The head line is byte for byte what a one-line consumer always parsed,
# and no added line can be mistaken for another diagnostic.
case_dir prefix
printf 'fn main() {\n    let x: int = (1 + (2 * 3)\n}\n' >"$tmp/prefix/main.b"
cat >"$tmp/prefix.check.expected" <<'EOF'
main.b:2:30: error: expected ')'
    let x: int = (1 + (2 * 3)
                             ^
note: '(' opened at main.b:2:18
note: in function main, declared at main.b:1:4
main.b: stopped before type checking
EOF
expect_stderr prefix check
test "$(head -n 1 "$tmp/prefix.check.stderr")" = "main.b:2:30: error: expected ')'"
test "$(grep -Ec '^[^ :]+:[0-9]+:[0-9]+: (error|warning):' \
    "$tmp/prefix.check.stderr")" -eq 1
# `parse` renders through the lexer/parser path, without a module loader.
sed '$d' "$tmp/prefix.check.expected" >"$tmp/prefix.parse.expected"
expect_stderr prefix parse

# A tab is copied and every other character is measured in terminal cells:
# two for each CJK character and the emoji, none for a combining accent. The
# CRLF line ending never reaches the excerpt.
case_dir wide
printf 'fn main() {\r\n\tlet s: string = "\xe6\x97\xa5\xe6\x9c\xac\xf0\x9f\x99\x82e\xcc\x81" + nope\r\n}\r\n' \
    >"$tmp/wide/main.b"
{
    # `nope` starts at byte 36 of the line (a byte column, as always).
    printf 'main.b:2:36: error: unknown name '"'"'nope'"'"'\n'
    printf '\tlet s: string = "\xe6\x97\xa5\xe6\x9c\xac\xf0\x9f\x99\x82e\xcc\x81" + nope\n'
    # 17 cells of `let s: string = "`, 6 of 日本🙂, 1 of é, 4 of `" + `.
    printf '\t%28s^\n' ''
    printf 'note: in function main, declared at main.b:1:4\n'
} >"$tmp/wide.check.expected"
expect_stderr wide check

# The resolver reports from inside a body without tracking the function;
# the note still names it. A bracket left open by a damaged statement is
# not the next statement's context, and a block's own `{` is named only
# for its missing `}`.
case_dir body
cat >"$tmp/body/main.b" <<'EOF'
fn helper() {
    let q: Undefined = 1
}
fn main() {}
EOF
cat >"$tmp/body.check.expected" <<'EOF'
main.b:2:12: error: unknown type 'Undefined'
    let q: Undefined = 1
           ^
note: in function helper, declared at main.b:1:4
EOF
expect_stderr body check

# A field default is checked inside a function no one declared; it gets no
# function note rather than one naming a synthesized `$defaults` at 1:1.
case_dir field
cat >"$tmp/field/main.b" <<'EOF'
class C {
    x: int = "s"
    fn init() {}
}
fn main() {}
EOF
cat >"$tmp/field.check.expected" <<'EOF'
main.b:2:14: error: expected int, got string
    x: int = "s"
             ^
EOF
expect_stderr field check

# A very long line is excerpted around the column, not printed whole once
# per diagnostic: 80 bytes before it, `...` where text was left out.
case_dir long
{
    printf 'fn main() {\n    let x: int ='
    for _ in $(seq 200); do printf ' 1 +'; done
    printf ' nope\n}\n'
} >"$tmp/long/main.b"
{
    printf 'main.b:2:818: error: unknown name '"'"'nope'"'"'\n'
    printf '...'
    for _ in $(seq 20); do printf '1 + '; done
    printf 'nope\n%83s^\n' ''
    printf 'note: in function main, declared at main.b:1:4\n'
} >"$tmp/long.check.expected"
expect_stderr long check

case_dir stale
cat >"$tmp/stale/main.b" <<'EOF'
fn main() {
    foo(1, 2
    let y = 3
}
fn later() {
    let z = 4
}
EOF
cat >"$tmp/stale.check.expected" <<'EOF'
main.b:3:5: error: expected ')'
    let y = 3
    ^
note: '(' opened at main.b:2:8
note: in function main, declared at main.b:1:4
main.b:3:11: error: expected ':' — beans requires the type here
    let y = 3
          ^
note: in function main, declared at main.b:1:4
main.b:6:11: error: expected ':' — beans requires the type here
    let z = 4
          ^
note: in function later, declared at main.b:5:4
main.b: stopped before type checking
EOF
expect_stderr stale check

echo 'ok diagnostic context: head line, caret, opened/function/generic/import notes, tabs, wide characters, CRLF'
