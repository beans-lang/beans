#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fs-source.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking Beans-written high-level file helpers"
mkdir "$tmp/interp" "$tmp/native" "$tmp/asan"
./build/beansc run test/cases/fs_source.b -- "$tmp/interp" >"$tmp/interp.out"
./build/beansc build test/cases/fs_source.b -o "$tmp/fs-native" >"$tmp/build"
"$tmp/fs-native" "$tmp/native" >"$tmp/native.out"

diff -u test/cases/fs_source.out "$tmp/interp.out"
diff -u test/cases/fs_source.out "$tmp/native.out"
assert_defined() {
    awk -v label="; $1" '
        $0 == label { found = 1; next }
        found && /^define / { exit 0 }
        found { exit 1 }
        END { if (!found) exit 1 }
    ' build/fs_source.ll
}
assert_defined std.fs.read_bytes
assert_defined std.fs.read
assert_defined std.fs.write_bytes
assert_defined std.fs.copy
if grep -Eq 'beans_file_(read_all|read_all_b|write_all|append_all|write_all_b|append_all_b)' \
    build/beans_rt.c; then
    echo "migrated file helpers still exist in the native runtime" >&2
    exit 1
fi
grep -q 'call i64 @beans_file_copy_out' build/fs_source.ll

clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/fs_source.ll build/beans_rt.c -lm -o "$tmp/fs-asan"
# A leak is a sanitizer failure like any other: LeakSanitizer rides inside
# ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
# the status before reading the report, or this dies under `set -e` with the
# report still unread in the capture file.
if ! BEANS_NO_POOL=1 "$tmp/fs-asan" "$tmp/asan" \
        >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    echo "fs_source exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u test/cases/fs_source.out "$tmp/asan.out"

echo "ok File.open/read_at/write_at primitives with Beans policy code"
