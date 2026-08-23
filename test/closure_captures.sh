#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-closure-captures.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking value, pattern, and shared-cell closure captures"
./build/beansc run test/cases/closure_captures.b >"$tmp/interp"
./build/beansc build test/cases/closure_captures.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/closure_captures.out "$tmp/interp"
diff -u test/cases/closure_captures.out "$tmp/native.out"

# The immutable scalar lives directly in the closure environment. Variables
# changed outside or inside a closure still use the shared heap-cell path.
grep -q '%cap0.v = load i64' build/closure_captures.ll
test "$(grep -c '%cap0.c = load ptr' build/closure_captures.ll)" -eq 4

echo "ok immutable captures use values and mutable and pattern captures use shared cells"

echo "checking non-escaping stack closure environments"
./build/beansc mir test/cases/stack_closures.b >"$tmp/stack.mir"
./build/beansc run test/cases/stack_closures.b >"$tmp/stack.interp"
./build/beansc build test/cases/stack_closures.b -o "$tmp/stack.native" \
    >"$tmp/stack.build" 2>&1
"$tmp/stack.native" >"$tmp/stack.native.out"
diff -u test/cases/stack_closures.out "$tmp/stack.interp"
diff -u test/cases/stack_closures.out "$tmp/stack.native.out"

grep -Eq 'local .*stack-closure=[0-9]+' "$tmp/stack.mir"
test "$(grep -Ec 'closure .* effects=none stack-closure$' \
    "$tmp/stack.mir")" -eq 2

function_body() {
    local name=$1
    local destination=$2
    awk -v marker="; main.$name" '
        $0 == marker { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' build/stack_closures.ll >"$destination"
}

function_body local_total "$tmp/local-total.ll"
function_body escaping "$tmp/escaping.ll"
function_body mutable_total "$tmp/mutable-total.ll"
grep -q 'alloca \[2 x i64\]' "$tmp/local-total.ll"
grep -Eq 'call i64 @[^ (]+\(ptr ' "$tmp/local-total.ll"
if grep -q 'call ptr @beans_alloc\|%closure[.]fn' \
    "$tmp/local-total.ll"; then
    echo "non-escaping scalar closure still used its heap or indirect call" >&2
    exit 1
fi
grep -q 'call ptr @beans_alloc' "$tmp/escaping.ll"
grep -q 'call ptr @beans_alloc' "$tmp/mutable-total.ll"

echo "ok non-escaping scalar closures use stack storage and direct calls"

echo "checking closure environments wider than the inline header mask"
# 75 captures: the header mask spells 58 pointer-width slots, so the
# environment chains annex boxes off its last inline slot. Creation,
# reads through the chain, the walker, and teardown must all agree.
./build/beansc run test/cases/wide_closure.b >"$tmp/wide.interp"
./build/beansc build test/cases/wide_closure.b -o "$tmp/wide.native" \
    >"$tmp/wide.build" 2>&1
"$tmp/wide.native" >"$tmp/wide.native.out"
diff -u test/cases/wide_closure.out "$tmp/wide.interp"
diff -u test/cases/wide_closure.out "$tmp/wide.native.out"

echo "ok wide closures chain annex environments past the header mask"
