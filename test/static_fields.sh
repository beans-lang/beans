#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-static-fields.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/static_fields_ok.b >"$tmp/interp"
./build/beansc build test/cases/static_fields_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/static_fields_ok.out "$tmp/interp"
diff -u test/cases/static_fields_ok.out "$tmp/native.out"

if ./build/beansc check test/cases/static_fields_private_bad.b \
    >"$tmp/private" 2>&1; then
    echo "static_fields_private_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "is private to 'main.State'" "$tmp/private"

if ./build/beansc check test/cases/static_fields_modifier_bad.b \
    >"$tmp/modifier" 2>&1; then
    echo "static_fields_modifier_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "static field 'value' needs an initial value" "$tmp/modifier"
grep -Fq "static fields are not supported on generic classes" "$tmp/modifier"
grep -Fq "static fields are supported only on classes" "$tmp/modifier"

# Statics and singletons live for the whole process: nothing tears them down
# at exit, so a static that owns a value with a deinit prints the same bytes
# on both backends (issue #74, spec/SYNTAX.md). The case also covers the three
# deaths that DO happen while the program runs — a local leaving scope, a
# value taken out of a static container, a static overwritten — so a change
# that simply stopped running deinits fails here too.
./build/beansc run test/cases/static_teardown.b >"$tmp/teardown.interp"
./build/beansc build test/cases/static_teardown.b -o "$tmp/teardown" \
    >"$tmp/teardown.build" 2>&1
"$tmp/teardown" >"$tmp/teardown.native"
./build/beansc build --release test/cases/static_teardown.b \
    -o "$tmp/teardown.release" >"$tmp/teardown.release.build" 2>&1
"$tmp/teardown.release" >"$tmp/teardown.release.out"
diff -u test/cases/static_teardown.out "$tmp/teardown.interp"
diff -u test/cases/static_teardown.out "$tmp/teardown.native"
diff -u test/cases/static_teardown.out "$tmp/teardown.release.out"

echo "ok static class fields, startup values, assignment, and privacy"
