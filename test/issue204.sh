#!/usr/bin/env bash
# #204: one defect is one primary error at the place it happened, and
# recovery keeps the statements and declarations that follow it.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
python3=${PYTHON3:-python3}

# The campaign's authored expectations (tools/syntax_fuzz.py): location,
# message and an exact error count per defect, in every front-end mode.
args=()
for name in missing_operand literal_leading_dot literal_hex_fraction \
    string_newline_inside string_raw_unterminated string_unterminated_next_line_kept \
    newline_before_operator \
    closure_param_no_type closure_arrow_no_type function_type_missing_arrow \
    initializer_missing_comma initializer_list_no_type if_value_no_else \
    declaration_pub_local incomplete_member literal_hex_bad_digit literal_bin_bad_digit \
    lexical_unicode_identifier delimiter_missing_bracket \
    delimiter_missing_call_paren extra_generic_close_nested lexical_stray_character \
    operator_not_int operator_chained_comparison operator_mixed_numbers \
    match_arm_type_mismatch string_double_brace diagnostic_generic_binding \
    comment_unterminated comment_nested_unterminated diagnostic_interpolation \
    independent_errors_kept; do
    args+=(--case "$name")
done
"$python3" -B tools/syntax_fuzz.py --beansc "$bin" --ignore-baseline \
    --out "${ISSUE204_OUT:-build/issue204-discovery}" ${args+"${args[@]}"}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue204.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A parse that loops forever is the worst recovery of all; bound every run.
bounded() {
    perl -e 'alarm 20; exec @ARGV or die "exec: $!"' "$@"
}

# errors FILE: the number of primary errors in a diagnostics file.
errors() {
    grep -c ': error: ' "$1" || true
}

fail() {
    echo "$1" >&2
    cat "$2" >&2
    exit 1
}

# 1. Statements after a broken one survive, one error per broken statement.
cat >"$tmp/recovery.b" <<'EOF'
fn main() {
    let broken: string = "oops
    let kept: string = "okay"
    let a: int = 1 +
    let b: int = 2 +
    let end: int = 7
}
EOF
status=0
bounded "$bin" ast "$tmp/recovery.b" >"$tmp/recovery.out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "recovery.b: expected exit 1, got $status" "$tmp/recovery.out"
[ "$(errors "$tmp/recovery.out")" -eq 3 ] || fail "recovery.b: expected 3 errors" "$tmp/recovery.out"
for kept in '(let "kept"' '(let "a"' '(let "b"' '(let "end"'; do
    grep -Fq "$kept" "$tmp/recovery.out" || fail "recovery.b: lost $kept" "$tmp/recovery.out"
done
bounded "$bin" sem-probe visible "$tmp/recovery.b:6:21" >"$tmp/visible.out"
grep -Fq 'kept' "$tmp/visible.out" && grep -Fq 'end' "$tmp/visible.out" ||
    fail "recovery.b: completion lost the retained locals" "$tmp/visible.out"

# #214: a newline before an operator is one defect, including its closer;
# the following declaration and an independent error survive recovery.
cat >"$tmp/paren-lines.b" <<'EOF'
fn main() {
    let x: int = (1
        + (2 * 3))
    let kept: int = 7
    let broken: int = 1 +
    let end: int = 9
}
EOF
status=0
bounded "$bin" ast "$tmp/paren-lines.b" >"$tmp/paren-lines.out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "paren-lines.b: expected exit 1" "$tmp/paren-lines.out"
[ "$(errors "$tmp/paren-lines.out")" -eq 2 ] || fail "paren-lines.b: expected 2 independent errors" "$tmp/paren-lines.out"
for kept in '(let "kept"' '(let "broken"' '(let "end"'; do
    grep -Fq "$kept" "$tmp/paren-lines.out" || fail "paren-lines.b: lost $kept" "$tmp/paren-lines.out"
done

# 2. An open string ends with its line. The next line is code, quotes and
#    all; only a second open string right below is the same mistake.
cat >"$tmp/strings.b" <<'EOF'
import std.io
fn main() {
    let a: string = "one
    io.println("two")
    let b: string = "three
    four"
    io.println("abc
    let kept: int = 5
}
EOF
status=0
bounded "$bin" ast "$tmp/strings.b" >"$tmp/strings.out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "strings.b: expected exit 1, got $status" "$tmp/strings.out"
[ "$(errors "$tmp/strings.out")" -eq 3 ] || fail "strings.b: expected 3 errors" "$tmp/strings.out"
for where in 3:21 5:21 7:16; do
    grep -Fq "strings.b:$where: error: string not closed before end of line" "$tmp/strings.out" ||
        fail "strings.b: no unterminated-string error at $where" "$tmp/strings.out"
done
grep -Fq '(literal "\"two\"")' "$tmp/strings.out" ||
    fail "strings.b: the line after an open string was not parsed as code" "$tmp/strings.out"
grep -Fq '(let "kept"' "$tmp/strings.out" ||
    fail "strings.b: lost the statement after an open string in a call" "$tmp/strings.out"

# 3. A type body with a statement word in it, or never closed, still ends:
#    one error for the bad member, and the next declaration is parsed.
cat >"$tmp/bodies.b" <<'EOF'
class A {
    let x: int = 1
    y: int
}
enum E {
    a
    return
}
interface I {
    fn f() -> int
class B {
}
fn main() {
}
EOF
status=0
bounded "$bin" ast "$tmp/bodies.b" >"$tmp/bodies.out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "bodies.b: expected exit 1, got $status" "$tmp/bodies.out"
[ "$(errors "$tmp/bodies.out")" -eq 3 ] || fail "bodies.b: expected 3 errors" "$tmp/bodies.out"
grep -Fq "bodies.b:2:5: error: expected member name — 'let' is a reserved word" "$tmp/bodies.out" &&
grep -Fq "bodies.b:7:5: error: expected member name — 'return' is a reserved word" "$tmp/bodies.out" &&
grep -Fq "bodies.b:11:1: error: expected '}'" "$tmp/bodies.out" ||
    fail "bodies.b: errors are not at the broken members" "$tmp/bodies.out"
for kept in '(field "y"' '(class "B"' '(fn "main"'; do
    grep -Fq "$kept" "$tmp/bodies.out" || fail "bodies.b: lost $kept" "$tmp/bodies.out"
done
status=0
bounded "$bin" check test/fuzz/corpus/oop_recovery.b >"$tmp/corpus.out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "oop_recovery.b: expected exit 1, got $status" "$tmp/corpus.out"

# 4. A string `+` with a number on one side names the operator rule once,
#    not the operand mismatch that follows from it.
cat >"$tmp/plus.b" <<'EOF'
import std.io
fn main() {
    let a: string = "x"
    io.println("{1 + a}")
    let n: int = 1 + 2.5 as float
}
EOF
status=0
bounded "$bin" check "$tmp/plus.b" >"$tmp/plus.out" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ "$(errors "$tmp/plus.out")" -eq 2 ] &&
grep -Fq "plus.b:4:20: error: '+' is not defined for string" "$tmp/plus.out" &&
grep -Fq "plus.b:5:20: error: '+' needs matching numbers" "$tmp/plus.out" ||
    fail "plus.b: expected one operator error per line" "$tmp/plus.out"

echo 'ok #204: one primary per defect, retained statements and members, line-bounded strings'
