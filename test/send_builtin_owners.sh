#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-send-builtin-owners.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/send_builtin_owners.b -- \
    "$tmp/owner.dat" >"$tmp/interp"
./build/beansc build test/cases/send_builtin_owners.b \
    -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" "$tmp/native.dat" >"$tmp/native.out"
diff -u test/cases/send_builtin_owners.out "$tmp/interp"
diff -u test/cases/send_builtin_owners.out "$tmp/native.out"

if ./build/beansc check test/cases/send_builtin_owners_bad.b \
    >"$tmp/bad" 2>&1; then
    echo "send_builtin_owners_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "binding 'alias' needs 'move value' because Bytes is move-only" "$tmp/bad"
grep -q "Bytes has no method 'clone'" "$tmp/bad"
grep -q "needs T implements Sync, got Bytes" "$tmp/bad"
grep -q "binding 'alias' needs 'move value' because File is move-only" "$tmp/bad"
grep -q "binding 'alias' needs 'move value' because MMap is move-only" "$tmp/bad"
grep -q "non-Send type Mutex<main.Local>" "$tmp/bad"

echo "ok move-only Send Bytes, File, and MMap owners"
