#!/usr/bin/env bash
# Named imports: `import {name, other as alias} from path` binds exactly
# the selection — functions, types, enums, annotations, sub-packages of a
# namespace folder — with the same compile-time resolution as the
# module-qualified form. Positive cases run on the interpreter, a debug
# build and a release build and must agree byte-for-byte; the negative
# files lock the loader, resolver and checker diagnostics; the source
# re-render keeps the braces form instead of dropping it.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-named-imports.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_all_ways() {
    local source=$1 golden=$2 name
    name=$(basename "$source" .b)
    ./build/beansc run "$source" >"$tmp/$name.interp"
    diff -u "$golden" "$tmp/$name.interp"
    ./build/beansc build "$source" -o "$tmp/$name.debug" >/dev/null
    "$tmp/$name.debug" >"$tmp/$name.debug.out"
    diff -u "$golden" "$tmp/$name.debug.out"
    ./build/beansc build --release "$source" -o "$tmp/$name.release" \
        >/dev/null
    "$tmp/$name.release" >"$tmp/$name.release.out"
    diff -u "$golden" "$tmp/$name.release.out"
}

check_bad() {
    local file=$1 message=$2
    if ./build/beansc check "$file" >"$tmp/bad" 2>&1; then
        echo "$file unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -Fq "$message" "$tmp/bad"; then
        echo "missing '$message' in diagnostics for $file" >&2
        sed -n '1,40p' "$tmp/bad" >&2
        exit 1
    fi
}

run_all_ways test/cases/named_imports_ok.b test/cases/named_imports_ok.out
run_all_ways test/cases/named_imports_pkg/main.b \
    test/cases/named_imports_pkg/main.out

check_bad test/cases/named_imports_bad.b \
    "import name 'parse' is already declared in package 'main' — rename the import with 'as'"
check_bad test/cases/named_imports_bad.b \
    "package 'std.encoding.json' does not declare 'nope'"
check_bad test/cases/named_imports_bad.b \
    "'println' from std.io is a compiler builtin and can't be stored as a value — call it directly"
check_bad test/cases/named_imports_dup_bad.b \
    "import name 'parse' is already taken in this file by 'std.encoding.json.parse'"
check_bad test/cases/named_imports_syntax_bad.b \
    "an import list names at least one thing"
check_bad test/cases/named_imports_syntax_bad.b \
    "an import list cannot take 'as' — alias a name inside the braces instead"
check_bad test/cases/named_imports_pkg_bad/main.b \
    "'hidden' isn't pub in package 'app.tools'"

# The source re-render must keep the selection: a dropped braces list
# would round-trip as a module import and change what the file binds.
./build/beansc parse test/cases/named_imports_ok.b >"$tmp/render"
grep -Fq "import {println} from std.io" "$tmp/render"
grep -Fq "import {Value, Kind, parse, stringify, encode as to_json} from std.encoding.json" \
    "$tmp/render"
grep -Fq "import {json as j} from std.encoding" "$tmp/render"

echo "ok named imports: selection binds functions, types, enums, annotations and sub-packages; diagnostics and re-render hold"
