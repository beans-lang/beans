#!/usr/bin/env bash
# Generic relations as real types: a class pins a concrete argument at the
# implements site, the interface itself stands as a variable and parameter
# type, a pass-through generic class reaches the same interface at two
# different arguments, a generic bound pins or forwards one, and a base
# class is extended at a concrete argument. Every one of those dispatches
# through the vtable or calls a body that only exists once its arguments
# are bound, so the interpreter, a debug build and a release build must
# agree byte for byte — a null row or an unbound `T` shows up as a
# difference here. The negative file locks the diagnostics that keep the
# bindings honest.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-generic-interfaces.XXXXXX")
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

run_all_ways test/cases/generic_interfaces_ok.b \
    test/cases/generic_interfaces_ok.out

# the pinned argument is what the method must answer, and the error says so
# in the caller's terms rather than the interface's own type parameter
check_bad test/cases/generic_interfaces_bad.b \
    "'make' doesn't match the interface: expected fn() -> int, this is fn() -> string"
check_bad test/cases/generic_interfaces_bad.b \
    "class 'Wrong' must implement 'make' from 'main.Producer' or be marked abstract"
# one interface at two arguments is two types
check_bad test/cases/generic_interfaces_bad.b \
    "expected main.Producer<string>, got main.IntBox"
check_bad test/cases/generic_interfaces_bad.b \
    "expected main.Producer<string>, got main.BoxOf<int>"
# a bound pins the argument the same way an implements site does
check_bad test/cases/generic_interfaces_bad.b \
    "'through_bound' needs P implements main.Producer<int>, got main.BoxOf<string>"
# and a generic class's bound is checked where the type is named, not left for
# the backend — the same rule the collections rely on for Order and Clone keys
check_bad test/cases/generic_interfaces_bad.b \
    "Keeper needs P implements main.Producer<int>, got main.BoxOf<string>"

echo "ok generic relations: pinned arguments, interface-typed values, kept defaults, bounds, generic bases"
