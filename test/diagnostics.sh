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
# A piece that is one unresolvable name reads far more often as a brace
# somebody meant literally than as a typo, so the hint replaces the bare
# "unknown name" rather than following it — at the same column, which is
# what this file is here to hold: three errors for three names, each on the
# bytes the user wrote.
grep -Fq ":5:18: error: '{missing_piece}' in a string is an interpolation" \
    "$tmp/diagnostics_interpolation_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_interpolation_bad")" -eq 3
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

# #46: `?` may only cross an error boundary when the callee's error reaches the
# caller's — same type, a subtype, or a `to_error` hook. Every other shape is
# refused here, at the `?`, with a message about the program: one error each,
# naming both types and what is missing. It used to be accepted for a bare
# `f()?` and left to a backend the interpreter got wrong and native could not
# emit.
check_bad diagnostics_try_convert_no_hook_bad
grep -Fq "'?' can't turn main.DbError into Error — give main.DbError a \`fn to_error() -> Error\` method, or match on the Result and build the error yourself" \
    "$tmp/diagnostics_try_convert_no_hook_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_try_convert_no_hook_bad")" -eq 1

check_bad diagnostics_try_convert_builtin_src_bad
grep -Fq "'?' can't turn the builtin Error into main.MyErr — Error is a builtin and cannot carry a to_error method" \
    "$tmp/diagnostics_try_convert_builtin_src_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_try_convert_builtin_src_bad")" -eq 1

check_bad diagnostics_try_convert_wrong_return_bad
grep -Fq "main.Weird.to_error() answers int, which doesn't reach this function's error type Error" \
    "$tmp/diagnostics_try_convert_wrong_return_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_try_convert_wrong_return_bad")" -eq 1

check_bad diagnostics_try_convert_bad_shape_bad
grep -Fq "'?' needs main.Weird.to_error to be an instance method taking no arguments and no type parameters" \
    "$tmp/diagnostics_try_convert_bad_shape_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_try_convert_bad_shape_bad")" -eq 1

# Reaching the target as a subtype must not shed move-only ownership: a
# to_error answering a unique class widened to a shared interface is refused
# in the same words a plain widening uses.
check_bad diagnostics_try_convert_unique_bad
grep -Fq "can't erase move-only ownership by converting main.Pinned to main.AppError" \
    "$tmp/diagnostics_try_convert_unique_bad"
test "$(grep -c ': error:' "$tmp/diagnostics_try_convert_unique_bad")" -eq 1

# Only a class is an interface value, and an enum was the one record kind
# with no rule saying so (#87). Every spelling is refused at the declaration
# and names the enum and the type it reached for, including the shapes a rule
# written only for the reported case would have missed: two interfaces at
# once, payload variants, `enum(u8)` — whose value is a bare one-byte tag
# with no room for a descriptor at all — a generic enum, and a base class.
check_bad diagnostics_enum_relation_bad
grep -Fq "enum 'Colour' cannot implement 'main.Shows' — an interface value is an object with a descriptor and an enum value is a tag, so only a class can implement one" \
    "$tmp/diagnostics_enum_relation_bad"
grep -Fq "enum 'Signal' cannot implement 'main.Shows'" \
    "$tmp/diagnostics_enum_relation_bad"
grep -Fq "enum 'Signal' cannot implement 'main.Names'" \
    "$tmp/diagnostics_enum_relation_bad"
grep -Fq "enum 'Payment' cannot implement 'main.Shows'" \
    "$tmp/diagnostics_enum_relation_bad"
grep -Fq "enum 'Display' cannot implement 'main.Shows'" \
    "$tmp/diagnostics_enum_relation_bad"
grep -Fq "enum 'Cell' cannot implement 'main.Shows'" \
    "$tmp/diagnostics_enum_relation_bad"
grep -Fq "enum 'Rooted' cannot extend 'main.Holder' — enums have no base type" \
    "$tmp/diagnostics_enum_relation_bad"
# one per relation named, and nothing else: the uses further down the file —
# an interface parameter, a List element, a Map value, an interpolation — are
# the shapes that used to reach a backend, and the declaration is where they
# are stopped
test "$(grep -c ': error:' "$tmp/diagnostics_enum_relation_bad")" -eq 7
# and the refusal really does stop a build, not just `check`
if ./build/beansc build test/cases/diagnostics_enum_relation_bad.b \
       -o "$tmp/enum_relation" >/dev/null 2>&1; then
    echo "an enum naming a relation still built" >&2
    exit 1
fi
if [ -e "$tmp/enum_relation" ]; then
    echo "an enum naming a relation produced a binary" >&2
    exit 1
fi

echo "ok diagnostics: locations, imports, suggestions, wording, and recovery"
