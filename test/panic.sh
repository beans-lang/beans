#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-panic.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compiler=${BEANSC:-./build/beansc}
source_file=test/cases/panic_builtin.b

set +e
"$compiler" run "$source_file" >"$tmp/interpreter" 2>&1
interpreter_status=$?
set -e
test "$interpreter_status" -eq 3

"$compiler" build "$source_file" -o "$tmp/native" >/dev/null
set +e
"$tmp/native" >"$tmp/native.out" 2>&1
native_status=$?
set -e
test "$native_status" -eq 3
diff -u "$tmp/interpreter" "$tmp/native.out"
grep -q '^before panic$' "$tmp/interpreter"
grep -q '^runtime panic at 9:10: stopped$' "$tmp/interpreter"
if grep -q 'after panic' "$tmp/interpreter"; then
    echo "panic returned to the caller" >&2
    exit 1
fi

set +e
"$compiler" check test/cases/panic_no_argument.b \
    >"$tmp/no-argument" 2>&1
no_argument_status=$?
"$compiler" check test/cases/panic_wrong_type.b \
    >"$tmp/wrong-type" 2>&1
wrong_type_status=$?
set -e
test "$no_argument_status" -ne 0
test "$wrong_type_status" -ne 0
grep -q 'panic takes 1 argument' "$tmp/no-argument"
grep -q 'string' "$tmp/wrong-type"

echo "panic builtin ok"
