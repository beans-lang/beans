#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/access.h" <<'C'
#include <stdint.h>
typedef struct Handle Handle;
typedef struct Pair {
    int32_t left;
    uint64_t right;
    uint8_t bytes[4];
} Pair;
typedef union Word {
    uint32_t bits;
    float value;
} Word;
typedef enum Status { STATUS_OK = 0, STATUS_BAD = 2 } Status;
extern const int32_t version;
extern _Thread_local int32_t counter;
Handle* make_handle(void);
int32_t take(Handle*, Pair, Word, void (*callback)(void*, int32_t));
C
"$beansc" bindgen "$tmp/access.h" -o "$tmp/bindings.b" >"$tmp/bindgen.out"
"$beansc" check "$tmp/bindings.b" >"$tmp/check.out"
grep -F 'opaque struct Handle' "$tmp/bindings.b" >"$tmp/match"
grep -F 'union Word' "$tmp/bindings.b" >"$tmp/match"
grep -F 'bytes: [u8; 4]' "$tmp/bindings.b" >"$tmp/match"
grep -F 'thread_local var counter: i32' "$tmp/bindings.b" >"$tmp/match"
grep -F 'fn make_handle() -> RawPtr<Handle>' "$tmp/bindings.b" >"$tmp/match"
grep -F 'callback' "$tmp/bindings.b" >"$tmp/match"
grep -F 'fn status_bad() -> i32 { return 2 }' "$tmp/bindings.b" >"$tmp/match"

cat >"$tmp/unsupported.h" <<'C'
int variadic(const char*, ...);
C
if "$beansc" bindgen "$tmp/unsupported.h" -o "$tmp/bad.b" \
    >"$tmp/bad.out" 2>&1; then
    echo "bindgen accepted varargs" >&2
    exit 1
fi
"$beansc" bindgen "$tmp/unsupported.h" -o "$tmp/allowed.b" \
    --allow-unsupported >"$tmp/allowed.out"
grep -F 'skipped: variadic function' "$tmp/allowed.b" >"$tmp/match"

# Bindings are generated to be dropped into a real project, and every file in a
# package declares that package. Without --package the output has no clause at
# all, which loads only as a lone file — so a generated file beside a main.b was
# refused by the loader and nothing here noticed, because this file only ever
# checked the bindings on their own.
project="$tmp/project"
mkdir -p "$project"
cat >"$project/beans.pot" <<'MOD'
module bindgen_probe
MOD
cat >"$project/main.b" <<'BEANS'
package main

import std.io

fn main() {
    var seen: i32 = 0
    unsafe { seen = version }
    io.println("{seen}")
}
BEANS
"$beansc" bindgen "$tmp/access.h" -o "$project/bindings.b" --package main \
    >"$tmp/pkg.out"
head -3 "$project/bindings.b" | grep -Fx 'package main' >"$tmp/match"
"$beansc" check "$project/main.b" >"$tmp/pkg.check"

# The same generation without --package is still a valid lone file, and it is
# still refused inside the package — that refusal is the whole reason the option
# exists, so it is checked rather than assumed.
"$beansc" bindgen "$tmp/access.h" -o "$project/bindings.b" >"$tmp/nopkg.out"
if "$beansc" check "$project/main.b" >"$tmp/nopkg.check" 2>&1; then
    echo "bindgen: a clause-less file was accepted inside a package" >&2
    cat "$tmp/nopkg.check" >&2
    exit 1
fi
grep -F 'has no package clause' "$tmp/nopkg.check" >/dev/null

echo "bindgen ok"
