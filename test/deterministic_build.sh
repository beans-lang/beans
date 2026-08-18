#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-deterministic.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc build --release examples/hello.b -o "$tmp/hello" >/dev/null
cp "$tmp/hello" "$tmp/hello.first"
cp build/hello.ll "$tmp/hello.first.ll"
./build/beansc build --release examples/hello.b -o "$tmp/hello" >/dev/null
cp build/hello.ll "$tmp/hello.second.ll"
cmp "$tmp/hello.first.ll" "$tmp/hello.second.ll"
cmp "$tmp/hello.first" "$tmp/hello"

./build/beansc build --release examples/shop/main.b -o "$tmp/shop" >/dev/null
cp "$tmp/shop" "$tmp/shop.first"
cp build/main.ll "$tmp/shop.first.ll"
./build/beansc build --release examples/shop/main.b -o "$tmp/shop" >/dev/null
cp build/main.ll "$tmp/shop.second.ll"
cmp "$tmp/shop.first.ll" "$tmp/shop.second.ll"
cmp "$tmp/shop.first" "$tmp/shop"

echo "ok deterministic single-file and multi-package LLVM and binaries"
