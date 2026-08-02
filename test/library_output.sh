#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
beansc=${BEANSC:-"$root/build/beansc"}
tmp=$(mktemp -d)
default_archive="$root/build/libbeans_test_library.a"
trap 'rm -rf "$tmp"; rm -f "$default_archive" "$default_archive.beans.o" "$default_archive.runtime.o" "$default_archive.ffi.o"' EXIT

cat >"$tmp/library.b" <<'BEANS'
extern "C" opaque struct Handle
extern "C" struct Pair {
    left: i32
    right: i32
}
pub extern "C" fn add(a: i32, b: i32) -> i32 as "beans_access_add" {
    return a + b
}
pub extern "C" fn pair_sum(value: Pair) -> i32 as "beans_access_pair_sum" {
    return value.left + value.right
}
pub extern "C" fn handle_accepted(value: RawPtr<Handle>) -> bool as "beans_access_handle_accepted" {
    return true
}
BEANS
cat >"$tmp/caller.c" <<'C'
#include <stdio.h>
#include "library.h"
int main(void) {
    printf("%d %d %d\n", beans_access_add(20, 22),
           beans_access_pair_sum((Pair){20, 22}),
           beans_access_handle_accepted((Handle*)0));
    return 0;
}
C
cat >"$tmp/cpp_caller.cpp" <<'CPP'
#include "library.h"
int main() {
    Pair pair{20, 22};
    return beans_access_add(20, 22) == 42 &&
                   beans_access_pair_sum(pair) == 42
               ? 0
               : 1;
}
CPP
cat >"$tmp/dynamic_caller.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) return 3;
    int32_t (*add)(int32_t, int32_t) =
        (int32_t (*)(int32_t, int32_t))dlsym(library, "beans_access_add");
    if (!add || add(20, 22) != 42) return 4;
    return dlclose(library) == 0 ? 0 : 5;
}
C

if [[ $(uname -s) == Darwin ]]; then
    shared="$tmp/libbeans_access.dylib"
    shared_link=(-L"$tmp" -lbeans_access)
    library_path=DYLD_LIBRARY_PATH
else
    shared="$tmp/libbeans_access.so"
    shared_link=(-L"$tmp" -lbeans_access)
    library_path=LD_LIBRARY_PATH
fi
if ! "$beansc" build --emit shared --header "$tmp/library.h" \
    "$tmp/library.b" -o "$shared" \
    >"$tmp/shared.build" 2>&1; then
    cat "$tmp/shared.build" >&2
    exit 1
fi
grep -F 'typedef struct Handle Handle;' "$tmp/library.h" >"$tmp/match"
grep -F 'typedef struct Pair Pair;' "$tmp/library.h" >"$tmp/match"
grep -F 'int32_t beans_access_add(int32_t a, int32_t b);' \
    "$tmp/library.h" >"$tmp/match"
grep -F 'bool beans_access_handle_accepted(Handle* value);' \
    "$tmp/library.h" >"$tmp/match"
clang -I"$tmp" "$tmp/caller.c" "${shared_link[@]}" -o "$tmp/shared_caller"
env "$library_path=$tmp" "$tmp/shared_caller" >"$tmp/shared.out"
grep -Fx '42 42 1' "$tmp/shared.out" >"$tmp/match"
clang++ -I"$tmp" "$tmp/cpp_caller.cpp" "${shared_link[@]}" \
    -o "$tmp/cpp_caller"
env "$library_path=$tmp" "$tmp/cpp_caller"
if [[ $(uname -s) == Darwin ]]; then
    clang "$tmp/dynamic_caller.c" -o "$tmp/dynamic_caller"
else
    clang "$tmp/dynamic_caller.c" -ldl -o "$tmp/dynamic_caller"
fi
"$tmp/dynamic_caller" "$shared"
if [[ $(uname -s) == Darwin ]]; then
    nm -gU "$shared" >"$tmp/symbols"
else
    nm -D --defined-only "$shared" >"$tmp/symbols"
fi
grep -F 'beans_access_add' "$tmp/symbols" >"$tmp/match"
grep -F 'beans_access_pair_sum' "$tmp/symbols" >"$tmp/match"
if grep -F 'beans_alloc' "$tmp/symbols" >"$tmp/unwanted"; then
    echo "runtime symbol leaked from shared library" >&2
    exit 1
fi

archiver=$(command -v ar)
if ! "$beansc" build --emit static --ar "$archiver" "$tmp/library.b" \
    -o "$tmp/libbeans_access.a" >"$tmp/static.build" 2>&1; then
    cat "$tmp/static.build" >&2
    exit 1
fi
clang -I"$tmp" "$tmp/caller.c" "$tmp/libbeans_access.a" \
    -pthread -lm -o "$tmp/static_caller"
"$tmp/static_caller" >"$tmp/static.out"
diff -u "$tmp/shared.out" "$tmp/static.out"
ar -t "$tmp/libbeans_access.a" >"$tmp/archive"
grep -F '.beans.o' "$tmp/archive" >"$tmp/match"
grep -F 'beans_rt.' "$tmp/archive" >"$tmp/match"
grep -F '.ffi.o' "$tmp/archive" >"$tmp/match"

mkdir -p "$tmp/project"
cat >"$tmp/project/beans.pot" <<'MOD'
module beans_test_library
kind library
MOD
cat >"$tmp/project/api.b" <<'BEANS'
pub fn doubled(value: i32) -> i32 {
    return value * 2
}
pub extern "C" fn answer() -> i32 as "beans_test_answer" {
    return doubled(21)
}
BEANS
rm -f "$default_archive"
"$beansc" build --header "$tmp/project/library.h" \
    "$tmp/project/api.b" >"$tmp/default.build"
[[ -f "$default_archive" ]]
grep -F "built build/libbeans_test_library.a" "$tmp/default.build" >"$tmp/match"
grep -F 'int32_t beans_test_answer(void);' \
    "$tmp/project/library.h" >"$tmp/match"
if "$beansc" run "$tmp/project/api.b" >"$tmp/library.run" 2>&1; then
    echo "a library ran without an application entry point" >&2
    exit 1
fi
grep -F 'a library cannot run' "$tmp/library.run" >"$tmp/match"

mkdir -p "$tmp/bad_library"
cat >"$tmp/bad_library/beans.pot" <<'MOD'
module bad_library
kind library
MOD
cat >"$tmp/bad_library/main.b" <<'BEANS'
fn main() {}
BEANS
if "$beansc" build "$tmp/bad_library/main.b" \
    >"$tmp/bad_library.out" 2>&1; then
    echo "a library was allowed to declare main" >&2
    exit 1
fi
grep -F "a library cannot declare 'main'" \
    "$tmp/bad_library.out" >"$tmp/match"

cat >"$tmp/no_main.b" <<'BEANS'
pub fn helper() -> i32 {
    return 42
}
BEANS
if "$beansc" build "$tmp/no_main.b" >"$tmp/no_main.out" 2>&1; then
    echo "an application binary linked without main" >&2
    exit 1
fi
grep -F "an application needs 'fn main()'" \
    "$tmp/no_main.out" >"$tmp/match"

cat >"$tmp/bad_main.b" <<'BEANS'
fn main(value: i32) {}
BEANS
if "$beansc" build "$tmp/bad_main.b" >"$tmp/bad_main.out" 2>&1; then
    echo "an invalid main signature was accepted" >&2
    exit 1
fi
grep -F "main must be 'fn main()'" \
    "$tmp/bad_main.out" >"$tmp/match"

mkdir -p "$tmp/bad_kind"
cat >"$tmp/bad_kind/beans.pot" <<'MOD'
module bad_kind
kind plugin
MOD
cat >"$tmp/bad_kind/api.b" <<'BEANS'
pub fn helper() -> i32 {
    return 42
}
BEANS
if "$beansc" check "$tmp/bad_kind/api.b" \
    >"$tmp/bad_kind.out" 2>&1; then
    echo "an unknown project kind was accepted" >&2
    exit 1
fi
grep -F "kind needs exactly 'kind application' or 'kind library'" \
    "$tmp/bad_kind.out" >"$tmp/match"

cat >"$tmp/second.b" <<'BEANS'
pub extern "C" fn multiply(a: i32, b: i32) -> i32 as "beans_access_multiply" {
    return a * b
}
BEANS
if [[ $(uname -s) == Darwin ]]; then
    second_shared="$tmp/libbeans_second.dylib"
else
    second_shared="$tmp/libbeans_second.so"
fi
"$beansc" build --emit shared --header "$tmp/second.h" \
    "$tmp/second.b" -o "$second_shared" >"$tmp/second.build"
cat >"$tmp/two_libraries.c" <<'C'
#include <stdio.h>
#include "library.h"
#include "second.h"
int main(void) {
    printf("%d %d\n", beans_access_add(20, 22),
           beans_access_multiply(6, 7));
    return 0;
}
C
clang -I"$tmp" "$tmp/two_libraries.c" \
    -L"$tmp" -lbeans_access -lbeans_second \
    -o "$tmp/two_libraries"
env "$library_path=$tmp" \
    "$tmp/two_libraries" >"$tmp/two_libraries.out"
if ! grep -Fx '42 42' "$tmp/two_libraries.out" >"$tmp/match"; then
    cat "$tmp/two_libraries.out" >&2
    exit 1
fi

echo "library output ok"
