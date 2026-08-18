#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
if (( $# )); then
    compilers=("$@")
else
    compilers=("$root/build/beansc")
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-system.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/include dir" "$tmp/lib dir" "$tmp/project"
include_fs="$tmp/include dir"
lib_fs="$tmp/lib dir"

cat >"$tmp/fake_pkg_config.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_escaped(const char* value) {
    for (; *value; ++value) {
        if (*value == ' ' || *value == '\t') putchar('\\');
        putchar(*value);
    }
}

int main(int argc, char** argv) {
    if (argc != 3 || strcmp(argv[2], "system-probe") != 0) return 1;
    const char* include = getenv("BEANS_TEST_INCLUDE");
    const char* lib = getenv("BEANS_TEST_LIB");
    if (!include || !lib) return 2;
    if (strcmp(argv[1], "--cflags") == 0) {
        printf("-I"); print_escaped(include);
        printf(" -DSYSTEM_PROBE=1\n");
    } else if (strcmp(argv[1], "--variable=includedir") == 0) {
        print_escaped(include); putchar('\n');
    } else if (strcmp(argv[1], "--libs-only-L") == 0) {
        printf("-L"); print_escaped(lib); putchar('\n');
    }
    else if (strcmp(argv[1], "--libs-only-l") == 0)
        printf("-lsystem_probe\n");
    else if (strcmp(argv[1], "--libs-only-other") != 0)
        return 3;
    return 0;
}
C

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        pkg_config="$tmp/fake-pkg-config.exe"
        test_include=$(cygpath -m "$tmp/include dir")
        test_lib=$(cygpath -m "$tmp/lib dir")
        ;;
    *)
        pkg_config="$tmp/fake-pkg-config"
        test_include="$tmp/include dir"
        test_lib="$tmp/lib dir"
        ;;
esac
clang "$tmp/fake_pkg_config.c" -o "$pkg_config"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) pkg_config=$(cygpath -m "$pkg_config") ;;
esac

cat >"$tmp/system_probe.c" <<'C'
#if defined(_WIN32)
__declspec(dllexport)
#endif
int system_probe_value(void) { return 42; }
C
case "$(uname -s)" in
    Darwin)
        clang -dynamiclib "$tmp/system_probe.c" \
            -o "$lib_fs/libsystem_probe.dylib"
        native_name="$tmp/project/system-probe-app"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        clang -shared "$tmp/system_probe.c" \
            -o "$lib_fs/system_probe.dll"
        test -f "$lib_fs/system_probe.lib"
        native_name="$tmp/project/system-probe-app.exe"
        ;;
    *)
        clang -shared -fPIC "$tmp/system_probe.c" \
            -o "$lib_fs/libsystem_probe.so"
        native_name="$tmp/project/system-probe-app"
        ;;
esac

cat >"$include_fs/system_probe.h" <<'C'
#ifndef SYSTEM_PROBE
#error pkg-config cflags were not passed to Clang
#endif
int system_probe_value(void);
C

cat >"$tmp/project/main.b" <<'BEANS'
package main

import std.io

fn main() {
    unsafe { io.println("{system_probe_value()}") }
}
BEANS

export PKG_CONFIG="$pkg_config"
export BEANS_TEST_INCLUDE="$test_include"
export BEANS_TEST_LIB="$test_lib"
runtime_path="$root/runtime/beans_rt.c"
stdlib_path="$root/stdlib/std"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        runtime_path=$(cygpath -m "$runtime_path")
        stdlib_path=$(cygpath -m "$stdlib_path")
        ;;
esac
export BEANS_RUNTIME="$runtime_path"
export BEANS_STDLIB="$stdlib_path"

for compiler in "${compilers[@]}"; do
    test -x "$compiler"
    name=$(basename "$compiler")
    printf 'module system_probe\n' >"$tmp/project/beans.pot"

    (
        cd "$tmp/project"
        "$compiler" pot add --system system-probe >"$tmp/$name.add"
    )
    grep -qx 'added system system-probe' "$tmp/$name.add"
    grep -qx '# beansc:system system-probe begin' "$tmp/project/beans.pot"
    grep -Fqx "link all search \"$test_lib\"" "$tmp/project/beans.pot"
    grep -qx 'link all library "system_probe"' "$tmp/project/beans.pot"
    grep -qx '# beansc:system system-probe end' "$tmp/project/beans.pot"

    (
        cd "$tmp/project"
        "$compiler" pot add --system system-probe >"$tmp/$name.keep"
    )
    grep -qx 'kept system system-probe' "$tmp/$name.keep"
    (
        cd "$tmp/project"
        "$compiler" pot update --system system-probe >"$tmp/$name.update"
    )
    grep -qx 'kept system system-probe' "$tmp/$name.update"

    "$compiler" bindgen --system system-probe system_probe.h \
        --only system_probe_value --package main \
        -o "$tmp/project/system_probe_bindings.b" >"$tmp/$name.bindgen"
    grep -Fq 'fn system_probe_value() -> i32' \
        "$tmp/project/system_probe_bindings.b"
    "$compiler" check "$tmp/project/main.b" >"$tmp/$name.check"
    (
        cd "$tmp/project"
        "$compiler" pot tidy >"$tmp/$name.tidy"
    )
    grep -qx '# beansc:system system-probe begin' "$tmp/project/beans.pot"
    test "$("$compiler" run "$tmp/project/main.b")" = "42"
    "$compiler" build "$tmp/project/main.b" -o "$native_name" \
        >"$tmp/$name.build"
    case "$(uname -s)" in
        Darwin)
            test "$(DYLD_LIBRARY_PATH="$lib_fs" "$native_name")" = "42" ;;
        MINGW*|MSYS*|CYGWIN*)
            cp "$lib_fs/system_probe.dll" "$tmp/project/system_probe.dll"
            test "$("$native_name" | tr -d '\r')" = "42" ;;
        *)
            test "$(LD_LIBRARY_PATH="$lib_fs" "$native_name")" = "42" ;;
    esac

    if (
        cd "$tmp/project"
        "$compiler" pot add --system '../bad' \
            >"$tmp/$name.bad-name" 2>&1
    ); then
        echo "$name accepted an unsafe system package name" >&2
        exit 1
    fi
    grep -Fq 'invalid pkg-config package name' "$tmp/$name.bad-name"

    (
        cd "$tmp/project"
        "$compiler" pot remove --system system-probe >"$tmp/$name.remove"
    )
    grep -qx 'removed system system-probe' "$tmp/$name.remove"
    if grep -q 'beansc:system\|link all' "$tmp/project/beans.pot"; then
        echo "$name left generated system links in beans.pot" >&2
        exit 1
    fi
    if (
        cd "$tmp/project"
        "$compiler" pot update --system system-probe \
            >"$tmp/$name.update-missing" 2>&1
    ); then
        echo "$name updated a missing system package" >&2
        exit 1
    fi
    grep -Fq "system package 'system-probe' is not present" \
        "$tmp/$name.update-missing"
done

echo "ok system package add, bindgen discovery, validation, and remove"
