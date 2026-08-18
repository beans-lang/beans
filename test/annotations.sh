#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-annotations.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compilers=("$root/build/beansc")

reject_with() {
    local compiler=$1 file=$2 label=$3
    shift 3
    local output="$tmp/$label.$(basename "$compiler")"
    if "$compiler" check "$file" >"$output" 2>&1; then
        echo "$(basename "$compiler") accepted invalid annotation case $label" >&2
        exit 1
    fi
    local pattern
    for pattern in "$@"; do
        if ! grep -Fq "$pattern" "$output"; then
            echo "$(basename "$compiler") missed '$pattern' in $label" >&2
            sed -n '1,160p' "$output" >&2
            exit 1
        fi
    done
}

for compiler in "${compilers[@]}"; do
    "$compiler" check test/cases/annotations_ok.b >"$tmp/ok.$(basename "$compiler")"
    "$compiler" check test/cases/encoding_json_typed_contract.b \
        >"$tmp/json-contract.$(basename "$compiler")"
    "$compiler" check test/cases/encoding_xml_typed_contract.b \
        >"$tmp/xml-contract.$(basename "$compiler")"
    "$compiler" check test/cases/runtime_hooks_ok.b \
        >"$tmp/runtime-hooks.$(basename "$compiler")"
    "$compiler" run test/cases/runtime_hooks_ok.b \
        >"$tmp/runtime-hooks-tree.$(basename "$compiler")"
    diff -u test/cases/runtime_hooks_ok.out \
        "$tmp/runtime-hooks-tree.$(basename "$compiler")"
    "$compiler" build test/cases/runtime_hooks_ok.b \
        -o "$tmp/runtime-hooks-native.$(basename "$compiler")"
    "$tmp/runtime-hooks-native.$(basename "$compiler")" \
        >"$tmp/runtime-hooks-native-out.$(basename "$compiler")"
    diff -u test/cases/runtime_hooks_ok.out \
        "$tmp/runtime-hooks-native-out.$(basename "$compiler")"
    for runtime_case in runtime_hooks_threads runtime_hooks_async; do
        "$compiler" check "test/cases/$runtime_case.b" \
            >"$tmp/$runtime_case-check.$(basename "$compiler")"
        perl -e 'alarm 45; exec @ARGV' \
            "$compiler" run "test/cases/$runtime_case.b" \
            >"$tmp/$runtime_case-tree.$(basename "$compiler")"
        diff -u "test/cases/$runtime_case.out" \
            "$tmp/$runtime_case-tree.$(basename "$compiler")"
        "$compiler" build "test/cases/$runtime_case.b" \
            -o "$tmp/$runtime_case-native.$(basename "$compiler")"
        perl -e 'alarm 45; exec @ARGV' \
            "$tmp/$runtime_case-native.$(basename "$compiler")" \
            >"$tmp/$runtime_case-native-out.$(basename "$compiler")"
        diff -u "test/cases/$runtime_case.out" \
            "$tmp/$runtime_case-native-out.$(basename "$compiler")"
    done
    reject_with "$compiler" test/cases/annotations_bad.b bad \
        "does not target type declarations" \
        "must be a compile-time constant" \
        "is not repeatable" \
        "has no argument named 'unknown'" \
        "is missing required argument 'path'" \
        "expected string" \
        "annotation argument 'path' is written twice"
    reject_with "$compiler" test/cases/annotation_schema_bad.b schema \
        "unknown annotation target 'wrong'" \
        "annotation target 'function' is written twice" \
        'annotation retention must be "source", "tool", or "runtime"' \
        "has unsupported type fn()" \
        "must be a compile-time constant"
    reject_with "$compiler" test/cases/annotation_unknown_bad.b unknown \
        "unknown annotation '@missing'"
    reject_with "$compiler" test/cases/annotation_name_bad.b name \
        "is not lowercase snake_case"
    reject_with "$compiler" test/cases/runtime_hooks_bad.b runtime_hooks \
        "@runtime_hook needs 'before', 'after_return', or both" \
        "handler 'main.missing_handler' does not exist" \
        "handler 'main.wrong_signature' must be a concrete" \
        "handler 'main.wrong_parameters' first parameter must be a borrowed string target" \
        "parameter 2 must be borrowed int for annotation field 'value'" \
        "@runtime_hook annotation cannot use source retention" \
        "@runtime_hook annotation cannot target type declarations" \
        "runtime hook annotation '@active' needs a concrete" \
        "@runtime_start needs a concrete" \
        "a lifecycle function cannot be both @runtime_start and @runtime_stop" \
        "@runtime_hook handler cannot itself use a runtime hook annotation"
    reject_with "$compiler" \
        test/cases/runtime_hooks_async_bad.b runtime_hooks_async \
        "@runtime_hook before handler 'main.rejected_async_handler' must be a concrete, synchronous" \
        "runtime hook annotation '@active' needs a concrete, synchronous" \
        "@runtime_start needs a concrete, synchronous" \
        "@runtime_stop needs a concrete, synchronous"
    reject_with "$compiler" test/cases/encoding_json_typed_bad.b json_typed \
        "JSON name 'same' maps to both 'first' and 'second'" \
        "ignored JSON field 'value' needs a default value" \
        "@json.bytes is not supported by typed JSON yet" \
        "JSON name 'user_name' maps to both 'userName' and 'user_name'" \
        "does not support recursive schema" \
        "main.PayloadEvent" \
        "needs a struct or List<struct>, got main.ClassTarget" \
        "needs a struct or List<struct>, got Map<int, string>" \
        "needs a struct or List<struct>, got Result<int" \
        "defaulted JSON field 'value' is not supported" \
        "Bytes" \
        "typed JSON list items must be scalar or struct values" \
        "cannot combine ignored fields with nested structs or lists" \
        "typed JSON encoding needs a struct or List<struct>, got int"
    reject_with "$compiler" test/cases/encoding_xml_typed_bad.b xml_typed \
        "XML element name 'same' maps to both 'first' and 'second'" \
        "XML attribute name 'same' maps to both 'first' and 'second'" \
        "cannot be both an attribute and text" \
        "has more than one @xml.text field" \
        "ignored XML field 'value' needs a default value" \
        "@xml.ignore is not supported by typed XML decoding yet" \
        "defaulted XML field 'value' is not supported" \
        "XML root name for main.EmptyRoot cannot be empty" \
        "typed XML list elements must be scalar or struct values, got List<int>" \
        "needs a struct or List<struct>, got main.ClassTarget" \
        "needs a struct or List<struct>, got int" \
        "list decoding needs a struct item, got int"
done

"$root/build/beansc" parse test/cases/annotations_ok.b >"$tmp/self.ast"
for output in "$tmp/self.ast"; do
    grep -Fq '@target(value: ["type", "function"' "$output"
    grep -Fq 'annotation mark {' "$output"
    grep -Fq '@mark(value: "local")' "$output"
    grep -Fq '@mark(value: "payload")' "$output"
done
"$root/build/beansc" parse test/cases/runtime_hooks_ok.b \
    >"$tmp/runtime-hooks-self.ast"
for output in "$tmp/runtime-hooks-self.ast"; do
    grep -Fq '@runtime_hook(before: "trace_before", after_return: "trace_after")' \
        "$output"
    grep -Fq '@runtime_start' "$output"
    grep -Fq '@runtime_stop' "$output"
done
"$root/build/beansc" lsp-probe \
    test/cases/annotations_ok.b:20:3 >"$tmp/annotation.hover"
grep -Fq 'annotation mark' "$tmp/annotation.hover"

# Stdlib annotations keep their package identity when the source file itself
# is open, and docs written above @target/@retention reach hover.
json_source="$root/stdlib/std/encoding/json/json.b"
"$root/build/beansc" lsp-probe \
    "$json_source:47:16" >"$tmp/json-annotation.hover"
grep -Fq 'pub annotation name' "$tmp/json-annotation.hover"
grep -Fq "Overrides one field or payload-free enum variant's JSON name." \
    "$tmp/json-annotation.hover"
"$root/build/beansc" sem-probe symbol \
    test/cases/encoding_json_typed_contract.b:8:11 \
    >"$tmp/json-annotation.symbol"
grep -Fq 'symbol annotation:std.encoding.json::name' \
    "$tmp/json-annotation.symbol"
grep -Fq 'decl stdlib/std/encoding/json/json.b:47:16' \
    "$tmp/json-annotation.symbol"

valid="$tmp/valid"
mkdir -p "$valid/tags"
cat >"$valid/beans.pot" <<'EOF'
module annotation_fixture
EOF
cat >"$valid/tags/tags.b" <<'EOF'
package tags

import std.io

@target(value: ["function"])
pub annotation note {
    value: string
}

annotation hidden {}

@runtime_hook(before: "active_note_before")
@target(value: ["function"])
pub annotation active_note {
    value: string
}

fn active_note_before(target: string, value: string) {
    io.println("package-hook:{target}:{value}")
}
EOF
cat >"$valid/main.b" <<'EOF'
package main

import annotation_fixture.tags as tags

@tags.note(value: "qualified")
@tags.active_note(value: "qualified")
fn main() {}
EOF

private="$tmp/private"
mkdir -p "$private/tags"
cp "$valid/beans.pot" "$private/beans.pot"
cp "$valid/tags/tags.b" "$private/tags/tags.b"
cat >"$private/main.b" <<'EOF'
package main

import annotation_fixture.tags as tags

@tags.hidden
fn main() {}
EOF

for compiler in "${compilers[@]}"; do
    "$compiler" check "$valid/main.b" >"$tmp/package.$(basename "$compiler")"
    "$compiler" run "$valid/main.b" >"$tmp/package-run.$(basename "$compiler")"
    grep -Eq '^package-hook:.*main:qualified$' \
        "$tmp/package-run.$(basename "$compiler")"
    reject_with "$compiler" "$private/main.b" private \
        "isn't pub in package 'annotation_fixture.tags'"
done

echo "annotations: ok"
