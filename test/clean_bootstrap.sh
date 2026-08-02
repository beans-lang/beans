#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-clean-bootstrap.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

(
    cd "$root"
    tar --exclude=.git --exclude=build --exclude=dist -cf "$tmp/source.tar" .
)
mkdir "$tmp/source"
tar xf "$tmp/source.tar" -C "$tmp/source"

make -C "$tmp/source" -j2
make -C "$tmp/source" test-bootstrap
mv "$tmp/source/build/beansc0" "$tmp/beansc0.unavailable"
(
    cd "$tmp/source"
    ./build/beansc check examples/hello.b >"$tmp/check.out"
    ./build/beansc build examples/hello.b -o "$tmp/hello" >/dev/null
)
grep -q ': ok$' "$tmp/check.out"
test "$("$tmp/hello")" = "hello from beans"

echo "ok clean checkout bootstrap and no-stage0 workflow"
