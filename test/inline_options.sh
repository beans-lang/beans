#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-inline-option.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking inline Option value and ABI parity"
./build/beansc run examples/inline_options.b >"$tmp/interp"
./build/beansc build examples/inline_options.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/inline_option.out "$tmp/interp"
diff -u test/cases/inline_option.out "$tmp/native.out"
awk '
    $0 == "; pass" { found = 1; next }
    found && /^define \{ ?i1, %bs[.]Pair ?\} @[^ (]+\(\{ ?i1, %bs[.]Pair ?\}/ {
        exit 0
    }
    found { exit 1 }
    END { if (!found) exit 1 }
' build/inline_options.ll
grep -Eq 'insertvalue \{ ?i1, %bs[.]Pair ?\} zeroinitializer, i1 true, 0' \
    build/inline_options.ll
grep -Eq '\{ ?i1, \{ ?i1, %bs[.]Pair ?\} ?\}' build/inline_options.ll

echo "ok Option methods across scalars, ARC, structs, arrays, SIMD, slices, and nesting"
