#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case "$(uname -s):$(uname -m)" in
    Darwin:arm64) triple=arm64-apple-darwin; wrong_os=linux ;;
    Linux:x86_64) triple=x86_64-unknown-linux-gnu; wrong_os=macos ;;
    Linux:aarch64|Linux:arm64) triple=aarch64-unknown-linux-gnu; wrong_os=macos ;;
    *) echo "unsupported test host" >&2; exit 1 ;;
esac

mkdir -p "$tmp/native/lib"
cat >"$tmp/native/manifest.c" <<'C'
int manifest_value(void) { return 42; }
C
if [[ $(uname -s) == Darwin ]]; then
    clang -dynamiclib "$tmp/native/manifest.c" -o "$tmp/native/lib/libmanifest_value.dylib"
    library_path=DYLD_LIBRARY_PATH
else
    clang -shared -fPIC "$tmp/native/manifest.c" -o "$tmp/native/lib/libmanifest_value.so"
    library_path=LD_LIBRARY_PATH
fi
cat >"$tmp/beans.pot" <<MOD
module link_manifest
link all search "native/lib"
link $wrong_os library "this_must_not_be_linked"
link $triple library "manifest_value"
MOD
cat >"$tmp/main.b" <<'BEANS'
package main

import std.io
extern "C" fn manifest_value() -> i32
fn main() {
    unsafe { io.println(manifest_value()) }
}
BEANS
"$beansc" build "$tmp/main.b" -o "$tmp/native_program" >"$tmp/build.out"
env "$library_path=$tmp/native/lib" "$tmp/native_program" >"$tmp/output"
grep -Fx '42' "$tmp/output" >"$tmp/match"

echo "link manifest ok"
