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

# beansc0 is internal bootstrap code. Nothing named after it may reach an
# install tree, a launcher, or a PATH entry.
if find "$tmp/root" -name '*beansc0*' -print -quit | grep -q .; then
    echo "make install placed a beansc0 path in the install tree" >&2
    find "$tmp/root" -name '*beansc0*' >&2
    exit 1
fi
if grep -rl beansc0 "$tmp/root" >/dev/null 2>&1; then
    echo "an installed file mentions beansc0" >&2
    grep -rl beansc0 "$tmp/root" >&2
    exit 1
fi

# An upgrade over an install that predates this rule has to remove the stale
# stage-0 compiler rather than leave it on PATH.
touch "$bin/beansc0" "$lib/beansc0"
make install PREFIX=/usr/local DESTDIR="$tmp/root"
test ! -e "$bin/beansc0"
test ! -e "$lib/beansc0"

# DESTDIR is a staging path. Point the generated wrapper at that staged tree
# exactly as a package manager would after installing it at /usr/local.
sed "s|/usr/local|$tmp/root/usr/local|g" "$bin/beansc" >"$tmp/beansc"
chmod +x "$tmp/beansc"

(
    cd "$tmp"
    "$tmp/beansc" check "$root/examples/hello.b" >check.out
    grep -q ': ok$' check.out
    test "$("$tmp/beansc" run "$root/examples/hello.b")" = "hello from beans"
    "$tmp/beansc" build "$root/examples/hello.b" -o hello >/dev/null
    test "$(./hello)" = "hello from beans"
    "$tmp/beansc" doctor >doctor.out
    grep -q '^check: *ready$' doctor.out
    grep -q "^standard library: *$share/lib/std\$" doctor.out
)

cmp build/beansc "$lib/beansc"
test -f "$share/LICENSE"
cmp LICENSE "$share/LICENSE"
test -f "$lib/wasm_host.c"
echo "ok installed beansc is self-hosted, complete, and carries no beansc0"
