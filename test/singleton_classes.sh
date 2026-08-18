#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-singleton.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/singleton_ok.b >"$tmp/interp"
./build/beansc build test/cases/singleton_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/singleton_ok.out "$tmp/interp"
diff -u test/cases/singleton_ok.out "$tmp/native.out"

if ./build/beansc check test/cases/singleton_new_bad.b \
    >"$tmp/new" 2>&1; then
    echo "singleton_new_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "cannot build singleton class 'App' — use App.instance" "$tmp/new"

if ./build/beansc check test/cases/singleton_modifier_bad.b \
    >"$tmp/modifier" 2>&1; then
    echo "singleton_modifier_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "singleton initializer cannot take arguments" "$tmp/modifier"
grep -Fq "singleton class cannot declare deinit" "$tmp/modifier"
grep -Fq "a singleton class cannot be generic" "$tmp/modifier"
grep -Fq "a singleton class cannot be abstract" "$tmp/modifier"
grep -Fq "a singleton class cannot be extended" "$tmp/modifier"

echo "ok singleton instance, eager init, and declaration rules"
