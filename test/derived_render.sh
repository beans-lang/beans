#!/usr/bin/env bash
# Derived rendering (#34): the shapes the language builds out of other values
# — maps as {k: v}, results as ok(x)/err(e), class instances as
# Name { field: value } — each have a form a string can hold. The two
# compilers must print the golden byte for byte, and a value the backends
# cannot render alike must be refused by the checker, not by an emitter.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-derived-render.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

BEANSC=${BEANSC:-./build/beansc}

run_both() {
    local name=$1
    "$BEANSC" run "test/cases/$name.b" >"$tmp/$name.interp"
    "$BEANSC" build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
}

# A piece the backends cannot render alike must be refused at check time,
# with a message about the program rather than about an emitter, and both
# compilers must refuse it the same way.
refuse_both() {
    local name=$1
    local needle=$2
    if "$BEANSC" run "test/cases/$name.b" >"$tmp/$name.run" 2>&1; then
        echo "interpreter accepted $name, which must be refused" >&2
        exit 1
    fi
    if "$BEANSC" build "test/cases/$name.b" -o "$tmp/$name.bin" \
        >"$tmp/$name.buildbad" 2>&1; then
        echo "native accepted $name, which must be refused" >&2
        exit 1
    fi
    grep -q "$needle" "$tmp/$name.run"
    grep -q "$needle" "$tmp/$name.buildbad"
    # The refusal names the program's type, never the emitter.
    if grep -qi "emitter\|LLVM" "$tmp/$name.run" "$tmp/$name.buildbad"; then
        echo "$name was refused by an emitter, not the checker" >&2
        exit 1
    fi
}

echo "checking maps, options and lists render alike on both backends"
run_both derived_render_ok

echo "checking a value the backends cannot render alike is refused"
refuse_both derived_render_class_bad "give it a string form first"

echo "derived render ok"
