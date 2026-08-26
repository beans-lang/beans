#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-diagnostics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

check_bad() {
    local name=$1
    if ./build/beansc check "test/cases/$name.b" >"$tmp/$name" 2>&1; then
        echo "$name unexpectedly passed" >&2
        exit 1
    fi
}

check_bad diagnostics_interpolation_bad
grep -Fq ":4:22: error: unknown name 'missing_first'" \
    "$tmp/diagnostics_interpolation_bad"
grep -Fq ":5:18: error: unknown name 'missing_piece'" \
    "$tmp/diagnostics_interpolation_bad"
grep -Fq ":6:21: error: unknown name 'missing_last'" \
    "$tmp/diagnostics_interpolation_bad"

check_bad diagnostics_missing_import_bad
grep -Fq ":1:1: error: no module 'std.nonexistent'" \
    "$tmp/diagnostics_missing_import_bad"

check_bad diagnostics_names_bad
grep -Fq "unknown name 'countr' — did you mean 'counter'?" \
    "$tmp/diagnostics_names_bad"
grep -Fq "Point has no field 'ex' — did you mean 'x'?" \
    "$tmp/diagnostics_names_bad"
grep -Fq "Point has no method 'distanc' — did you mean 'distance'?" \
    "$tmp/diagnostics_names_bad"
grep -Fq "no_value() has no return type, so it can't return a value" \
    "$tmp/diagnostics_names_bad"
if grep -Fq "main.Point" "$tmp/diagnostics_names_bad"; then
    echo "a diagnostic leaked the root package ID" >&2
    exit 1
fi

check_bad diagnostics_arity_bad
grep -Fq "'add' takes 2 arguments but got 1" \
    "$tmp/diagnostics_arity_bad"

check_bad diagnostics_unknown_type_bad
test "$(grep -c ': error:' "$tmp/diagnostics_unknown_type_bad")" -eq 1

check_bad diagnostics_trailing_operator_bad
test "$(grep -c ': error:' "$tmp/diagnostics_trailing_operator_bad")" -eq 1

check_bad diagnostics_unterminated_string_bad
test "$(grep -c ': error:' "$tmp/diagnostics_unterminated_string_bad")" -eq 1

# `while` is not a keyword, so it used to parse as a name and fail at the
# condition — then the recovery ate the block's closing brace and put two more
# errors on correct lines. One error, naming the loop keyword that exists.
check_bad diagnostics_while_bad
grep -Fq "there is no 'while' — beans has one loop keyword: write 'for condition { … }'" \
    "$tmp/diagnostics_while_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_while_bad")" -eq 1

# `X.y` where X is a type used to blame X: "unknown name 'Gap'" for a class
# that resolves a line earlier, or "package has no function 'Gap'" across a
# package boundary. Neither named the part that is wrong.
check_bad diagnostics_statics_bad
grep -Fq "Gap has no static field 's2p' — did you mean 's2'?" \
    "$tmp/diagnostics_statics_bad"
grep -Fq "'twice' is a static method — call it as Gap.twice(...)" \
    "$tmp/diagnostics_statics_bad"
grep -Fq "Payment has no variant 'cast' — did you mean 'cash'?" \
    "$tmp/diagnostics_statics_bad"
if grep -Fq "main.Gap" "$tmp/diagnostics_statics_bad"; then
    echo "a diagnostic leaked the root package ID" >&2
    exit 1
fi

# A string piece that opens with '{' fails three ways inside the braces, and
# the one line that fixes it used to come last. It comes alone now.
check_bad diagnostics_brace_piece_bad
grep -Fq "'{{' is not an escape" "$tmp/diagnostics_brace_piece_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_brace_piece_bad")" -eq 1

echo "ok diagnostics: locations, imports, suggestions, wording, and recovery"
