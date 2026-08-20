#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-send-handles.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/send_handles.b >"$tmp/interp"
./build/beansc build test/cases/send_handles.b \
    -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/send_handles.out "$tmp/interp"
diff -u test/cases/send_handles.out "$tmp/native.out"

echo "ok cross-thread move and destruction for Send standard-library handles"
