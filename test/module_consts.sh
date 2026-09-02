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

# The parser has no symbol table, so the message it gives a name here has to
# be true of every name that can appear — not only the constant it was
# written for.
check_bad const_arraylen_bad.b \
    "an array length must be an integer literal, not the name 'SIZE' — a length is read while types are laid out, which happens before any name has a value, module constants included" \
    "not the name 'count'" \
    "not the name 'Widget'" \
    "not the name 'nosuchname'"

# A parameter default waits on the same pass an array length does (#59). The
# message says which name it is and why, rather than "must be a constant
# literal" for a constant.
check_bad const_default_bad.b \
    "a parameter default must be a literal, not the name 'LIMIT' — a default is read while signatures are checked, which happens before any constant is folded, so a module const cannot be one yet" \
    "a parameter default must be a constant literal"

# `beansc hir` prints the signature stage, which runs before any constant is
# folded. A value it has not computed must not be rendered as an empty one.
./build/beansc hir test/cases/const_ok.b >"$tmp/hir" 2>&1
grep -q "^const main::C_ADD i8$" "$tmp/hir" ||
    { echo "beansc hir should print a constant with no folded value:" >&2
      grep "^const " "$tmp/hir" >&2; exit 1; }
if grep -qE "^const .* = *$" "$tmp/hir"; then
    echo "beansc hir printed a constant with an empty value:" >&2
    grep -E "^const .* = *$" "$tmp/hir" >&2
    exit 1
fi

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

echo "ok module constants: folding matches run time, bad initializers named"
