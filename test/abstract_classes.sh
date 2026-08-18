#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-abstract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/abstract_ok.b >"$tmp/interp"
./build/beansc build test/cases/abstract_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/abstract_ok.out "$tmp/interp"
diff -u test/cases/abstract_ok.out "$tmp/native.out"

if ./build/beansc check test/cases/abstract_contract_bad.b \
    >"$tmp/contract" 2>&1; then
    echo "abstract_contract_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "class 'Missing' must implement 'value'" "$tmp/contract"
grep -Fq "'value' replaces an inherited implementation or abstract method — mark it override" "$tmp/contract"
grep -Fq "class 'MissingInterface' must implement 'label'" "$tmp/contract"
grep -Fq "cannot build abstract class 'Base'" "$tmp/contract"

if ./build/beansc check test/cases/abstract_modifier_bad.b \
    >"$tmp/modifier" 2>&1; then
    echo "abstract_modifier_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "abstract method 'value' needs an abstract class" "$tmp/modifier"
grep -Fq "abstract method 'value' cannot have a body" "$tmp/modifier"

echo "ok abstract classes, contracts, construction, and overrides"
