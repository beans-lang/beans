#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

make install PREFIX=/usr/local DESTDIR="$tmp/root"
bin="$tmp/root/usr/local/bin"
lib="$tmp/root/usr/local/lib/beans"
share="$tmp/root/usr/local/share/beans"

# DESTDIR is a staging path. Point the generated wrapper at that staged tree
# exactly as a package manager would after installing it at /usr/local.
sed "s|/usr/local|$tmp/root/usr/local|g" "$bin/beansc" >"$tmp/beansc"
chmod +x "$tmp/beansc"
mv "$lib/beansc0" "$tmp/beansc0.unavailable"

(
    cd "$tmp"
    BEANS_STDLIB="$share/lib/std" \
    BEANS_RUNTIME="$lib/beans_rt.c" \
        "$tmp/beansc" check "$root/examples/hello.b" >check.out
    grep -q ': ok$' check.out
    BEANS_STDLIB="$share/lib/std" \
    BEANS_RUNTIME="$lib/beans_rt.c" \
        "$tmp/beansc" build "$root/examples/hello.b" -o hello >/dev/null
    test "$(./hello)" = "hello from beans"
)

cmp build/beansc "$lib/beansc"
test -f "$share/LICENSE"
cmp LICENSE "$share/LICENSE"
echo "ok installed beansc is self-hosted and works without beansc0"
