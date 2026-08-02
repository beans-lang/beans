#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/good.b" <<'BEANS'
extern "C" opaque struct Handle
extern "C" fn consume(value: RawPtr<Handle>) -> i32

fn probe() {
    unsafe {
        let value: RawPtr<Handle> = RawPtr.null()
        if !value.is_null() {
            consume(value)
        }
    }
}
BEANS
"$beansc" check "$tmp/good.b" >"$tmp/good.out"
grep -F 'ok' "$tmp/good.out" >"$tmp/match"

cat >"$tmp/bad.b" <<'BEANS'
extern "C" opaque struct Handle

fn bad() {
    let value: Handle
    let bytes: int = size_of(Handle)
    unsafe {
        let pointer: RawPtr<Handle> = RawPtr.alloc(1)
        pointer.read()
    }
}
BEANS
if "$beansc" check "$tmp/bad.b" >"$tmp/bad.out" 2>&1; then
    echo "opaque C types were accepted by value" >&2
    exit 1
fi
grep -F 'opaque C type' "$tmp/bad.out" >"$tmp/match"
if ! grep -F 'cannot allocate opaque C type' "$tmp/bad.out" \
    >"$tmp/match"; then
    cat "$tmp/bad.out" >&2
    exit 1
fi

echo "c opaque ok"
