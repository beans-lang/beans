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

echo "bindgen ok"
