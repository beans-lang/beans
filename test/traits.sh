#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-traits.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/traits_ok.b >"$tmp/interp"
./build/beansc build test/cases/traits_ok.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/traits_ok.out "$tmp/interp"
diff -u test/cases/traits_ok.out "$tmp/native.out"

./build/beansc run test/cases/send_containers_ok.b >"$tmp/send.interp"
./build/beansc build test/cases/send_containers_ok.b \
    -o "$tmp/send.native" >"$tmp/send.build" 2>&1
"$tmp/send.native" >"$tmp/send.native.out"
diff -u test/cases/send_containers_ok.out "$tmp/send.interp"
diff -u test/cases/send_containers_ok.out "$tmp/send.native.out"

if ./build/beansc check test/cases/traits_bad.b >"$tmp/bad" 2>&1; then
    echo "traits_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "generic bound 'Magic' is not an interface" "$tmp/bad"
grep -q "List<T> has no method 'clone'" "$tmp/bad"
grep -q "needs T implements Order, got main.Local" "$tmp/bad"
grep -q "cannot capture 'local' of non-Send type main.Local" "$tmp/bad"
grep -q "cannot capture 'shared' of non-Send type Shared<main.Local>" "$tmp/bad"
grep -q "closure returns non-Send type main.Local" "$tmp/bad"
grep -q "must capture move-only Send value 'bytes' with move(bytes)" "$tmp/bad"
grep -q "Map key needs Eq, got Shared<int>" "$tmp/bad"
grep -q "Map key needs Hash, got Shared<int>" "$tmp/bad"

if ./build/beansc check test/cases/send_containers_bad.b \
    >"$tmp/send.bad" 2>&1; then
    echo "send_containers_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "non-Send type List<main.Local>" "$tmp/send.bad"
grep -q "non-Send type Box<main.Local>" "$tmp/send.bad"
grep -q "non-Send type Arena<main.Local>" "$tmp/send.bad"
grep -q "non-Send type Map<string, main.Local>" "$tmp/send.bad"
grep -q "non-Send type OrderedMap<string, main.Local>" "$tmp/send.bad"
grep -q "non-Send type main.Parcel<main.Local>" "$tmp/send.bad"

echo "ok compiler-known interfaces, user interface bounds, and Send capture checks"
