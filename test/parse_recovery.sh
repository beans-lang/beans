#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "checking parser error recovery on half-typed code"

out=$(./build/beansc ast test/cases/recover.b 2>&1 || true)

# the incomplete member access is reported
grep -q "expected name after '.'" <<<"$out" ||
    { echo "FAIL: missing the member-access error" >&2; echo "$out" >&2; exit 1; }
# ...but the receiver is still under a field node (for completion)
grep -q '(field' <<<"$out" && grep -q '(name "u")' <<<"$out" ||
    { echo "FAIL: receiver 'u.' was dropped from the AST" >&2; echo "$out" >&2; exit 1; }
# ...and the following statement survived rather than being devoured
grep -q '(let "z"' <<<"$out" && grep -q '(literal "5")' <<<"$out" ||
    { echo "FAIL: 'let z' did not survive recovery" >&2; echo "$out" >&2; exit 1; }

echo "ok parser recovery: error reported, receiver kept, next statement survives"
