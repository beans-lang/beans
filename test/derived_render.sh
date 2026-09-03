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
    # A refusal here is the interesting failure — the checker let something
    # through that an emitter cannot produce — so say what it was instead of
    # dying on set -e with the reason buried in a temp file.
    if ! "$BEANSC" build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1; then
        echo "$name: the native build refused a checked program:" >&2
        cat "$tmp/$name.build" >&2
        exit 1
    fi
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

echo "checking maps, structs, classes and cycles render alike on both backends"
run_both derived_render_ok

# A class whose real type is not its declared one — an interface, a base a
# subclass extends — and a class carrying an unrenderable field, each refused
# at check time, the same way on both backends.
echo "checking an interface value is refused"
refuse_both derived_render_iface_bad "give it a string form first"
echo "checking a subclassed base is refused"
refuse_both derived_render_base_bad "give it a string form first"
echo "checking a class with an unrenderable field is refused"
refuse_both derived_render_opaque_bad "give it a string form first"
echo "checking join refuses an element with no string form"
refuse_both derived_render_join_bad "a string form first"

echo "derived render ok"
