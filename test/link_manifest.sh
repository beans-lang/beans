#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -n ${BEANSC:-} ]]; then
    compilers=("$BEANSC")
else
    compilers=("$root/build/beansc")
fi
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
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    "$compiler" run "$tmp/main.b" >"$tmp/$name.run"
    grep -Fx '42' "$tmp/$name.run" >/dev/null
    "$compiler" build "$tmp/main.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build"
    env "$library_path=$tmp/native/lib" "$tmp/$name.native" \
        >"$tmp/$name.output"
    grep -Fx '42' "$tmp/$name.output" >/dev/null
done

# A dependency owns its link rows. Consumers must get them without copying the
# search and library rows into their own manifest.
mkdir -p "$tmp/dependency/native/lib" "$tmp/consumer"
cp "$tmp/native/lib/libmanifest_value."* "$tmp/dependency/native/lib/"
cat >"$tmp/dependency/beans.pot" <<MOD
module linked_dependency
kind library
link all search "native/lib"
link $triple library "manifest_value"
MOD
cat >"$tmp/dependency/dependency.b" <<'BEANS'
package linked_dependency

extern "C" fn manifest_value() -> i32

pub fn value() -> i32 {
    unsafe { return manifest_value() }
}
BEANS
cat >"$tmp/consumer/beans.pot" <<'MOD'
module linked_consumer
require path "../dependency"
MOD
cat >"$tmp/consumer/main.b" <<'BEANS'
package main

import std.io
import linked_dependency

fn main() { io.println(linked_dependency.value()) }
BEANS
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    "$compiler" run --locked --offline "$tmp/consumer/main.b" \
        >"$tmp/$name.dependency.run"
    grep -Fx '42' "$tmp/$name.dependency.run" >/dev/null
    "$compiler" build --locked --offline "$tmp/consumer/main.b" \
        -o "$tmp/$name.dependency.native" \
        >"$tmp/$name.dependency.build"
    env "$library_path=$tmp/dependency/native/lib" \
        "$tmp/$name.dependency.native" \
        >"$tmp/$name.dependency.output"
    grep -Fx '42' "$tmp/$name.dependency.output" >/dev/null
done

# Repeat through the git dependency path. This proves fetched community
# packages propagate link rows too, not only local development dependencies.
mkdir -p "$tmp/git-source" "$tmp/remotes/example"
cp -R "$tmp/dependency/." "$tmp/git-source/"
git -C "$tmp/git-source" init -q
git -C "$tmp/git-source" config user.name "Beans Test"
git -C "$tmp/git-source" config user.email "beans@example.test"
git -C "$tmp/git-source" add .
git -C "$tmp/git-source" commit -qm linked
git -C "$tmp/git-source" tag v1
git init -q --bare "$tmp/remotes/example/linked.git"
git -C "$tmp/remotes/example/linked.git" symbolic-ref HEAD refs/heads/main
git -C "$tmp/git-source" remote add origin \
    "$tmp/remotes/example/linked.git"
git -C "$tmp/git-source" push -q origin HEAD:refs/heads/main --tags

mkdir -p "$tmp/git-consumer"
cat >"$tmp/git-consumer/beans.pot" <<'MOD'
module git_linked_consumer
require local.test/example/linked v1
MOD
cat >"$tmp/git-consumer/main.b" <<'BEANS'
package main

import std.io
import local.test/example/linked

fn main() { io.println(linked_dependency.value()) }
BEANS
export BEANS_HOME="$tmp/beans-home"
export GIT_ALLOW_PROTOCOL=file
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.file://$tmp/remotes/.insteadOf"
export GIT_CONFIG_VALUE_0="https://local.test/"
(cd "$tmp/git-consumer" && "${compilers[0]}" pot tidy)
commit=$(awk '$1 == "module" { print $4 }' "$tmp/git-consumer/beans.lock")
cached_lib="$BEANS_HOME/pkg/local.test/example/linked/$commit/native/lib"
for compiler in "${compilers[@]}"; do
    name=$(basename "$compiler")
    "$compiler" run --locked --offline "$tmp/git-consumer/main.b" \
        >"$tmp/$name.git.run"
    grep -Fx '42' "$tmp/$name.git.run" >/dev/null
    "$compiler" build --locked --offline "$tmp/git-consumer/main.b" \
        -o "$tmp/$name.git.native" >"$tmp/$name.git.build"
    env "$library_path=$cached_lib" "$tmp/$name.git.native" \
        >"$tmp/$name.git.output"
    grep -Fx '42' "$tmp/$name.git.output" >/dev/null
done

echo "link manifest run/build and dependency propagation ok"
