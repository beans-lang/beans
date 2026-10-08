#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${BEANSC:-./build/beansc}
python3=${PYTHON3:-python3}
args=()
for name in missing_operand literal_leading_dot literal_hex_fraction \
    string_newline_inside string_raw_unterminated newline_before_operator \
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
    --out "${ISSUE204_OUT:-build/issue204-discovery}" "${args[@]}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-issue204.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/recovery.b" <<'EOF'
fn main() {
    let broken: string = "oops
    let kept: string = "okay"
    let a: int = 1 +
    let b: int = 2 +
    let end: int = 7
}
EOF
if "$bin" ast "$tmp/recovery.b" >"$tmp/recovery.out" 2>&1; then
    echo "broken source unexpectedly parsed" >&2
    exit 1
fi
test "$(grep -c ': error:' "$tmp/recovery.out")" -eq 3
grep -Fq '(let "kept"' "$tmp/recovery.out"
grep -Fq '(let "end"' "$tmp/recovery.out"
"$bin" sem-probe visible "$tmp/recovery.b:6:21" >"$tmp/visible.out"
grep -Fq 'kept' "$tmp/visible.out"
grep -Fq 'end' "$tmp/visible.out"
echo 'ok #204: one primary per defect, retained statements, exact interpolation context'
