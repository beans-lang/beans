#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fs-source.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking Beans-written high-level file helpers"
mkdir "$tmp/interp" "$tmp/native" "$tmp/asan"
# The second argument is a tag unique to this run. The case writes a probe file
# into fs.temp_dir() to prove the directory it names is really writable, and
# that directory is shared with every other program on the machine — including
# a second copy of this suite in another worktree. mktemp already made the name
# unique, so the tag rides along rather than being invented again.
tag=$(basename "$tmp")
./build/beansc run test/cases/fs_source.b -- "$tmp/interp" "$tag-interp" >"$tmp/interp.out"
./build/beansc build test/cases/fs_source.b -o "$tmp/fs-native" >"$tmp/build"
"$tmp/fs-native" "$tmp/native" "$tag-native" >"$tmp/native.out"

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
assert_defined std.fs.exists
assert_defined std.fs.size
assert_defined std.fs.rename
assert_defined std.fs.remove
assert_defined std.fs.temp_dir
if grep -Eq 'beans_file_(read_all|read_all_b|write_all|append_all|write_all_b|append_all_b)' \
    build/beans_rt.c; then
    echo "migrated file helpers still exist in the native runtime" >&2
    exit 1
fi
grep -q 'call i64 @beans_file_copy_out' build/fs_source.ll
grep -q 'call i64 @beans_file_remove_out' build/fs_source.ll
grep -q 'call i64 @beans_file_exists' build/fs_source.ll
grep -q 'call ptr @beans_dir_temp' build/fs_source.ll

# Issue #167 was reported as "std.fs cannot delete a file". The capability was
# there — File.remove has always existed — but std.fs stopped at a path's bytes
# and never named its life, so a competent reader concluded the language could
# not delete at all and reached for a shell. The rule that closes it is that
# std.fs names *every* path-taking File static. File.open is the one exception:
# it answers a handle, which is the layer std.fs is written on top of.
#
# This reads the statics out of the compiler's own table rather than a list
# kept here, so a static added later without its fs spelling fails right here
# instead of being found by the next person who concludes it cannot be done.
# Directories are deliberately not covered: Dir.* is its own documented
# surface, and whether std.fs should absorb it is a separate decision.
awk '/^pub fn runtime_builtin_static/ { on = 1; next }
     /^pub fn / { on = 0 }
     on' src/runtime_abi.b |
    grep -oE '"File\.[a-z_]+"' | tr -d '"' | sed 's/^File\.//' |
    sort -u >"$tmp/file_statics"
count=$(wc -l <"$tmp/file_statics" | tr -d ' ')
if [ "$count" -lt 5 ]; then
    echo "read only $count File statics out of src/runtime_abi.b" >&2
    echo "the extraction has drifted; this check is not proving anything" >&2
    exit 1
fi
while read -r name; do
    [ "$name" = "open" ] && continue
    grep -q "^pub fn $name(" stdlib/std/fs/fs.b || {
        echo "File.$name takes a path but std.fs has no '$name'" >&2
        echo "std.fs names a file's whole life; add the spelling or say in" >&2
        echo "spec/SYNTAX.md why this one belongs only on the File builtin" >&2
        exit 1
    }
done <"$tmp/file_statics"
echo "  ($count File statics, every path-taking one spelled in std.fs)"

# temp_dir is Dir.temp_path under another name, not a second implementation.
grep -q 'return Dir.temp_path()' stdlib/std/fs/fs.b || {
    echo "std.fs.temp_dir no longer answers Dir.temp_path" >&2
    echo "two implementations of 'where do temp files go' will drift" >&2
    exit 1
}

# temp_dir promises "no trailing separator, so path.join produces one", and the
# environment is where a trailing one comes from. Both backends have to strip
# it, because a path joined against an untrimmed answer is a different string
# on each. This is the POSIX arm; the Windows arm trims a backslash the same
# way, has GetTempPath behind it when the environment names nothing, and is
# covered by the Windows legs through examples/files.b.
mkdir -p "$tmp/trailing"
cat >"$tmp/tempdir.b" <<'BEANS'
import std.fs
import std.io

fn main() {
    let dir: string = fs.temp_dir()
    io.println("{dir} {dir.ends_with("/")} {dir == Dir.temp_path()}")
}
BEANS
./build/beansc build "$tmp/tempdir.b" -o "$tmp/tempdir" >"$tmp/tempdir.build"
want="$tmp/trailing false true"
for leg in interp native; do
    if [ "$leg" = interp ]; then
        got=$(TMPDIR="$tmp/trailing///" ./build/beansc run "$tmp/tempdir.b")
    else
        got=$(TMPDIR="$tmp/trailing///" "$tmp/tempdir")
    fi
    [ "$got" = "$want" ] || {
        echo "fs.temp_dir kept a trailing separator on the $leg leg" >&2
        echo "  wanted: $want" >&2
        echo "  got:    $got" >&2
        exit 1
    }
done
echo "  (temp_dir trims a trailing separator on both backends)"

clang -O1 -g -pthread -fsanitize=address -Wno-override-module \
    build/fs_source.ll build/beans_rt.c -lm -o "$tmp/fs-asan"
# A leak is a sanitizer failure like any other: LeakSanitizer rides inside
# ASan on Linux and reports at exit, which makes the run exit non-zero. Hold
# the status before reading the report, or this dies under `set -e` with the
# report still unread in the capture file.
if ! BEANS_NO_POOL=1 "$tmp/fs-asan" "$tmp/asan" "$tag-asan" \
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
