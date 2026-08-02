#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/.*char version\[\] = "\([^"]*\)".*/\1/p' compiler/bootstrap/version.h)
runtime_abi=$(sed -n \
    's/.*runtime_abi_version = \([0-9][0-9]*\).*/\1/p' compiler/bootstrap/version.h)
platform="test-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [[ "$(uname -s)" == Linux ]]; then
    tools/make_linux_sysroot.sh "$tmp/sysroot"
    export BEANS_RELEASE_SYSROOT="$tmp/sysroot"
fi
SOURCE_DATE_EPOCH=946684800 \
    tools/package_release.sh "$version" "$platform" "$tmp/out1" >/dev/null
SOURCE_DATE_EPOCH=946684800 \
    tools/package_release.sh "$version" "$platform" "$tmp/out2" >/dev/null
cmp "$tmp/out1/"*.tar.gz "$tmp/out2/"*.tar.gz

mkdir "$tmp/unpacked"
tar xzf "$tmp/out1/"*.tar.gz -C "$tmp/unpacked"
root=$(find "$tmp/unpacked" -mindepth 1 -maxdepth 1 -type d)
test "$("$root/bin/beansc" --version)" = \
    "beansc $version (language 1.0, runtime ABI $runtime_abi)"
test "$(cat "$root/VERSION")" = \
    $'compiler='"$version"$'\nlanguage=1.0\nruntime_abi='"$runtime_abi"$'\nlicense=Apache-2.0'
test -f "$root/LICENSE"
cmp LICENSE "$root/LICENSE"
test -x "$root/bin/beansc0"
test -x "$root/bin/beansc.real"
cmp build/beansc "$root/bin/beansc.real"
cmp build/beansc0 "$root/bin/beansc0"
test -f "$root/bin/wasm_host.c"
test "$("$root/bin/beansc" run "$root/examples/hello.b")" = \
    "hello from beans"
(
    cd "$tmp"
    PATH="$root/bin:$PATH" beansc build "$root/examples/hello.b" \
        -o "$tmp/hello" >/dev/null
)
test "$("$tmp/hello")" = "hello from beans"
mv "$root/bin/beansc0" "$tmp/packaged-beansc0"
(
    cd "$tmp"
    PATH="$root/bin:$PATH" beansc check "$root/examples/hello.b" \
        >"$tmp/no-stage0.check"
)
grep -q ': ok$' "$tmp/no-stage0.check"

echo "ok reproducible, clean-tree release package with bundled compiler"
