#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-struct-methods.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/struct_methods_ok.b >"$tmp/interp"
./build/beansc build test/cases/struct_methods_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/struct_methods_ok.out "$tmp/interp"
diff -u test/cases/struct_methods_ok.out "$tmp/native.out"

if ./build/beansc check test/cases/struct_methods_bad.b >"$tmp/bad" 2>&1; then
    echo "struct_methods_bad.b unexpectedly passed" >&2
    exit 1
fi

grep -Fq "inout methods are supported only on structs" "$tmp/bad"
grep -Fq "struct methods cannot be named init" "$tmp/bad"
grep -Fq "'self' is borrowed here, so its fields can't be reassigned — declare the method 'inout fn'" "$tmp/bad"
grep -Fq "needs var, but 'point' is a let" "$tmp/bad"
grep -Fq "needs a mutable local receiver" "$tmp/bad"
grep -Fq "Cell needs 1 type argument" "$tmp/bad"
grep -Fq "expected main.Point initializer, got Other" "$tmp/bad"

echo "ok struct methods and generic structs"
