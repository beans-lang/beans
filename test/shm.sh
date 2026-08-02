#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-shm.XXXXXX")
# A shared-memory name outlives the process that made it, so it is unlinked on the
# way out whatever happens — a leaked name is a resource leak the OS keeps.
name="/beans_test_$$"
trap 'rm -rf "$tmp"; ./build/beansc run "$tmp/unlink.b" >/dev/null 2>&1 || true' EXIT

echo "checking shared memory in both backends"
./build/beansc run examples/shared_memory.b >"$tmp/interp"
./build/beansc build examples/shared_memory.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

diff -u - "$tmp/interp" <<'EXPECTED'
created 128 bytes
wrote back 7 99 255
second mapping sees 7 99
oversized request refused: invalid
zero size refused: invalid
unlinked true
gone after unlink: not_found
EXPECTED

echo "checking two separate processes see one region"
# The assertion that matters: this is what shared memory is *for*, and a single
# process mapping something twice would pass a weaker test while proving nothing.
cat >"$tmp/writer.b" <<WRITER
import std.io

fn main() {
    match MMap.open_shared("$name", 64, true) {
        ok(region) => {
            region.put_u64(0, 1234567890123)
            region.put_u32(8, 4242)
            region.put_u8(12, 200)
            io.println("writer done")
        }
        err(e) => io.println("writer failed {e.kind}")
    }
}
WRITER
cat >"$tmp/reader.b" <<READER
import std.io

fn main() {
    match MMap.open_shared("$name", 64, false) {
        ok(region) => io.println("reader {region.get_u64(0)} {region.get_u32(8)} {region.get_u8(12)}"),
        err(e) => io.println("reader failed {e.kind}"),
    }
}
READER
cat >"$tmp/unlink.b" <<UNLINK
import std.io

fn main() {
    match MMap.unlink_shared("$name") {
        ok(gone) => io.println("unlinked"),
        err(e) => io.println("already gone"),
    }
}
UNLINK

./build/beansc build "$tmp/writer.b" -o "$tmp/writer" >/dev/null 2>&1
./build/beansc build "$tmp/reader.b" -o "$tmp/reader" >/dev/null 2>&1

# Native writer, native reader: two processes, one region.
"$tmp/writer" >"$tmp/w1"
"$tmp/reader" >"$tmp/r1"
grep -q '^writer done$' "$tmp/w1"
diff -u - "$tmp/r1" <<'READBACK'
reader 1234567890123 4242 200
READBACK

# And across backends: the interpreter must see what a native binary wrote, which is
# the same check the differential suite makes for everything else, extended across a
# process boundary.
./build/beansc run "$tmp/reader.b" >"$tmp/r2"
diff -u "$tmp/r1" "$tmp/r2"
# The other direction too.
./build/beansc run "$tmp/writer.b" >/dev/null
"$tmp/reader" >"$tmp/r3"
diff -u "$tmp/r1" "$tmp/r3"

echo "checking a name that does not exist is an error, not an empty region"
cat >"$tmp/missing.b" <<'MISSING'
import std.io

fn main() {
    match MMap.open_shared("/beans_definitely_absent_9174", 64, false) {
        ok(region) => io.println("unexpected {region.len()}"),
        err(e) => io.println("absent: {e.kind}"),
    }
}
MISSING
./build/beansc run "$tmp/missing.b" >"$tmp/m1"
./build/beansc build "$tmp/missing.b" -o "$tmp/missing" >/dev/null 2>&1
"$tmp/missing" >"$tmp/m2"
diff -u "$tmp/m1" "$tmp/m2"
grep -q '^absent: not_found$' "$tmp/m1"

echo "checking the mapping is unmapped and nothing leaks"
./build/beansc build examples/shared_memory.b --emit ir >/dev/null
clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/shared_memory.ll build/beans_rt.c -lm -o "$tmp/asan" 2>"$tmp/asan.build"
BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"
if grep -q 'AddressSanitizer' "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"
if [[ "$(uname -s)" == Darwin ]] && command -v leaks >/dev/null 2>&1; then
    BEANS_NO_POOL=1 leaks --atExit -- "$tmp/native" >"$tmp/leaks" 2>&1 || true
    grep -q '0 leaks for 0 total leaked bytes' "$tmp/leaks"
fi

# Clean up the test's own name before the trap, so a failure above is what shows.
./build/beansc run "$tmp/unlink.b" >/dev/null

echo "ok shared memory: one region across processes and backends, with clean removal"
