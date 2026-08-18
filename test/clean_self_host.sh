#!/usr/bin/env bash
set -euo pipefail

# Prove that the tracked source builds in a clean checkout when given a released
# or otherwise trusted self-hosted compiler. No build artifact from the working
# tree may satisfy this test.

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-clean-self-host.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

(
    cd "$root"
    tar --exclude=.git --exclude=build --exclude=dist \
        --exclude=release-output --exclude=toolchains -cf "$tmp/source.tar" .
)
mkdir "$tmp/source"
tar xf "$tmp/source.tar" -C "$tmp/source"

BEANSC_BOOT="$root/build/beansc" make -C "$tmp/source" -j2
BEANSC="$tmp/source/build/beansc" bash "$tmp/source/test/fixpoint.sh"

(
    cd "$tmp/source"
    ./build/beansc check examples/hello.b >"$tmp/check.out"
    ./build/beansc build examples/hello.b -o "$tmp/hello" >/dev/null
)
grep -q ': ok$' "$tmp/check.out"
test "$("$tmp/hello")" = "hello from beans"

echo "ok clean checkout self-host build and fixed point"
