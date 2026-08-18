#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-resources.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking move-only resources through Result in both backends"
# This is the shape every OS handle in std uses, and until now `unique class` had no
# users anywhere in the tree — nothing was protecting these semantics.
./build/beansc run examples/resources.b >"$tmp/interp"
./build/beansc build examples/resources.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

echo "checking close order and the error path"
# Two resources in one scope close newest-first, and the close happens before the
# owning function's result is seen.
diff -u - "$tmp/interp" <<'EXPECTED'
slot 2 closed
slot 1 closed
used two, total 3
slot 3 closed
handed over 3
slot 4 closed
failed as expected: slot id must not be negative
borrowed slot 5
slot 5 closed
done
EXPECTED

echo "checking a resource opened before a failing ? still closes"
# The single most important line in that output is "slot 4 closed" appearing before
# the error is reported: slot 4 was already open when slot -1 failed. A resource left
# open on an early return is the bug this whole shape exists to prevent, so it gets
# its own assertion rather than only being covered by the diff above.
before=$(grep -n '^slot 4 closed$' "$tmp/interp" | cut -d: -f1)
after=$(grep -n '^failed as expected' "$tmp/interp" | cut -d: -f1)
if [[ -z "$before" || -z "$after" || "$before" -ge "$after" ]]; then
    echo "a resource opened before a failing ? was not closed first" >&2
    cat "$tmp/interp" >&2
    exit 1
fi

echo "checking no resource leaks under ASan"
./build/beansc build examples/resources.b --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/resources.ll build/beans_rt.c -lm -o "$tmp/asan" 2>"$tmp/asan.build"
BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

echo "checking the rules that make a handle safe"
expect_error() {
    local want=$1 source=$2
    if ./build/beansc check "$source" >"$tmp/err" 2>&1; then
        echo "$source unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -qF -- "$want" "$tmp/err"; then
        echo "$source did not report \"$want\"" >&2
        sed -n '1,20p' "$tmp/err" >&2
        exit 1
    fi
}
# Use after move is what makes a double close unwritable.
expect_error "value 's' was already moved" test/cases/resource_use_after_move.b
# No implicit copy, so two owners of one handle cannot exist.
expect_error "is move-only" test/cases/resource_no_copy.b
# A match binding borrows. Documented, and the reason `?` is the idiom for taking a
# resource out of a Result.
expect_error "can't move borrowed binding" test/cases/resource_move_out_of_match.b

echo "ok move-only resources: ownership, close order, error paths, and the rejections"
