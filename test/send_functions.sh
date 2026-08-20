#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$beansc" run "$root/test/cases/send_functions_ok.b" >"$tmp/interp"
diff -u "$root/test/cases/send_functions_ok.out" "$tmp/interp"

"$beansc" build "$root/test/cases/send_functions_ok.b" \
    -o "$tmp/native" >/dev/null
"$tmp/native" >"$tmp/native.out"
diff -u "$root/test/cases/send_functions_ok.out" "$tmp/native.out"

if "$beansc" check "$root/test/cases/send_functions_bad.b" \
    >"$tmp/bad" 2>&1; then
    echo "invalid send fn programs passed" >&2
    exit 1
fi
grep -q "non-Send type main.Local" "$tmp/bad"
grep -q "must own mutable or non-Sync capture 'count' with move(count)" \
    "$tmp/bad"
grep -q "thread.spawn needs a send fn closure" "$tmp/bad"
grep -q "because send fn() -> int is move-only" "$tmp/bad"
grep -q "send fn() -> int has no method 'clone'" "$tmp/bad"

echo "ok sendable function values"
