#!/usr/bin/env bash
# Module constants (#37): a `const NAME: T = <expr>` is folded once by the
# checker and every use is that value, so a const of type T behaves exactly
# like a `let: T` holding the same expression — proved by folding an
# expression into a const and computing it at run time, on both backends,
# and asserting equal. A non-foldable initializer is refused with a message
# that names what was not constant.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-module-consts.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_both() {
    local name=$1
    ./build/beansc run "test/cases/$name.b" >"$tmp/$name.interp"
    ./build/beansc build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

# Every message a bad const must produce, checked in the one file that holds
# it so the whole reason table is proved, not one row.
check_bad() {
    local file=$1
    shift
    if ./build/beansc check "test/cases/$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    local message
    for message in "$@"; do
        if ! grep -Fq "$message" "$tmp/bad"; then
            echo "$file missing message: $message" >&2
            cat "$tmp/bad" >&2
            exit 1
        fi
    done
}

run_both const_ok

check_bad const_bad.b \
    "const BAD_CALL is not a compile-time value: a call runs at run time" \
    "const BAD_CAST is not a compile-time value: 'as' converts at run time" \
    "const BAD_SIZEOF is not a compile-time value: size_of is answered after layout" \
    "const BAD_DIV is not a compile-time value: this divides by zero" \
    "const BAD_MODZERO is not a compile-time value: this divides by zero" \
    "const BAD_SHIFT is not a compile-time value: a i32 shift needs a count from 0 to 31, got 40" \
    "const BAD_U64 is not a compile-time value: this folds past 2^63 in u64" \
    "const BAD_FLOAT is not a compile-time value: '+' folds integers" \
    "const BAD_INTERP is not a compile-time value: a string constant cannot interpolate" \
    "List<int> has no compile-time value"

check_bad const_cycle_bad.b \
    "const SELF is defined in terms of itself" \
    "const A is defined in terms of itself"

check_bad const_assign_bad.b \
    "'LIMIT' is a constant and has no storage to assign to"

check_bad const_arraylen_bad.b \
    "an array length must be an integer literal — a module const is folded after types are laid out, so 'SIZE' cannot size an array"

echo "ok module constants: folding matches run time, bad initializers named"
