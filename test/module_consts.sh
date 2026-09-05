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
# #59: a constant sizes a fixed array, with the same value on both backends —
# once for every way a length can be written and every way a constant can be
# reached, and once for every position a fixed array type can sit in.
run_both const_arraylen_ok
run_both const_arraylen_places_ok

check_bad const_bad.b \
    "const BAD_CALL is not a compile-time value: a call runs at run time" \
    "const BAD_U64_ADD is not a compile-time value: a u64 at or above 2^63 is past the signed 64 bits this fold computes in, so '+' has no compile-time answer here" \
    "const BAD_U64_SHIFT is not a compile-time value: a u64 at or above 2^63" \
    "const BAD_U64_AND is not a compile-time value: a u64 at or above 2^63" \
    "const BAD_U64_GT is not a compile-time value: a u64 at or above 2^63" \
    "const BAD_U64_EQ is not a compile-time value: a u64 at or above 2^63" \
    "const BAD_U64_HEX_ADD is not a compile-time value: a u64 at or above 2^63" \
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

# An array length is an integer literal or a module constant (#59). Every
# other name, and every constant that cannot supply a length, is refused here
# — each told which of those it is, at the name, exactly once. The count is
# the guard against a cascade: a poisoned array type must not go on to be
# reported as a length nobody wrote.
check_bad const_arraylen_bad.b \
    "no module constant named 'count' is in scope — an array length is read while types are laid out, before any function runs, so it must be an integer literal or a module const" \
    "no module constant named 'nosuchname' is in scope" \
    "'Widget' is a class, not a module constant — an array length must be an integer literal or a module const" \
    "'helper' is a function, not a module constant" \
    "'N' is a type parameter, not a module constant — an array length must be an integer literal or a module const" \
    "an array length must be an integer, and const TEXT is a string" \
    "an array length must be an integer, and const FLAG is a bool" \
    "an array length must be an integer, and const REAL is a float" \
    "fixed array length must be between 1 and 4096, and const ZERO is 0" \
    "fixed array length must be between 1 and 4096, and const HUGE is 5000" \
    "fixed array length must be between 1 and 4096, and const OVER is 4097" \
    "fixed array length must be between 1 and 4096, and const NEGATIVE is -1" \
    "const CALLED is not a compile-time value: a call runs at run time" \
    "const SELFREF is defined in terms of itself"
if grep -Fq "SIZE" "$tmp/bad"; then
    echo "a constant that can size an array was reported" >&2
    cat "$tmp/bad" >&2
    exit 1
fi
test "$(grep -c ': error:' "$tmp/bad")" -eq 17

# The value a constant supplies is the same one wherever the type is written,
# including inside a string's `{}` piece — which is parsed after every other
# length in the file has been substituted, so it is the one path that has to
# look the constant up for itself.
check_bad const_arraylen_interp_bad.b \
    "an array length must be an integer, and const TEXT is a string" \
    "fixed array length must be between 1 and 4096, and const ZERO is 0" \
    "no module constant named 'nosuchconst' is in scope"
test "$(grep -c ': error:' "$tmp/bad")" -eq 3

# A parameter default is still a literal and not a constant: it is read while
# the signature holding it is lowered, and the fold runs at the end of that
# stage — which is where an array length reads it (#59). The message says
# which name it is and why the two positions differ, rather than "must be a
# constant literal" for a constant. The array length in the same file is the
# control: the same constant, in the position the ordering does reach.
check_bad const_default_bad.b \
    "a parameter default must be a literal, not the name 'LIMIT' — a default is read while the signature holding it is lowered, and constants are folded at the end of that stage, which is why a constant can size an array but cannot be a default" \
    "a parameter default must be a constant literal"
test "$(grep -c ': error:' "$tmp/bad")" -eq 2

# `beansc hir` prints the signature stage, and constants are folded in it
# (#59) — an array length reads one before any type is laid out. So the value
# is there, narrowed to the constant's own type: 100 + 100 is -56 in i8.
./build/beansc hir test/cases/const_ok.b >"$tmp/hir" 2>&1
grep -q "^const main::C_ADD i8 = -56$" "$tmp/hir" ||
    { echo "beansc hir should print a constant's folded value:" >&2
      grep "^const " "$tmp/hir" >&2; exit 1; }
# A constant that is not a compile-time value has none, and a stage dump says
# what the stage knows: no `= ` half rather than an empty one.
./build/beansc hir test/cases/const_bad.b >"$tmp/hirbad" 2>&1 || true
grep -q "^const main::BAD_CALL int$" "$tmp/hirbad" ||
    { echo "beansc hir should print an unfoldable constant with no value:" >&2
      grep "^const " "$tmp/hirbad" >&2; exit 1; }
for dump in "$tmp/hir" "$tmp/hirbad"; do
    if grep -qE "^const .* = *$" "$dump"; then
        echo "beansc hir printed a constant with an empty value:" >&2
        grep -E "^const .* = *$" "$dump" >&2
        exit 1
    fi
done

# pub const is the library case: a consumer in another package folds it,
# reaches it qualified and through an import binding, and uses it in a match
# arm — on both backends, against one golden. A non-pub const stays private.
./build/beansc run test/cases/const_pkg/main.b >"$tmp/pkg.interp"
./build/beansc build test/cases/const_pkg/main.b -o "$tmp/pkg.native" \
    >"$tmp/pkg.build" 2>&1
"$tmp/pkg.native" >"$tmp/pkg.native.out"
diff -u test/cases/const_pkg/main.out "$tmp/pkg.interp"
diff -u test/cases/const_pkg/main.out "$tmp/pkg.native.out"

if ./build/beansc check test/cases/const_pkg_private/main.b \
        >"$tmp/priv" 2>&1; then
    echo "a private cross-package const was reachable" >&2
    exit 1
fi
grep -Fq "constant 'secret.HIDDEN' isn't pub in package 'priv_app.secret'" \
    "$tmp/priv" ||
    { echo "private const message wrong:" >&2; cat "$tmp/priv" >&2; exit 1; }
# once for the read, once for the array length — a length is a constant use
# and gets the same refusal, not a "no such constant"
test "$(grep -c "isn't pub in package" "$tmp/priv")" -eq 2

echo "ok module constants: folding matches run time, bad initializers named"
