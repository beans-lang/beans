#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-interpreter-execution.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

bounded() {
    perl -e 'alarm 120; exec @ARGV or die "exec: $!"' "$@"
}

# Repeat typed literal use, captures and inout, then reuse the existing
# assignment cases that pin receiver/key/RHS order and one-time evaluation.
for source in test/cases/interpreter_execution.b \
              test/cases/parity/assign_eval_order.b \
              test/cases/parity/assign_short_circuit.b \
              test/cases/parity/slice_index_write.b; do
    name=$(basename "$source" .b)
    bounded ./build/beansc run "$source" >"$tmp/$name.interp"
    if [ "$name" = interpreter_execution ]; then
        diff -u test/cases/interpreter_execution.out "$tmp/$name.interp"
    fi
    for mode in debug release; do
        build=(./build/beansc build)
        if [ "$mode" = release ]; then build+=(--release); fi
        bounded "${build[@]}" "$source" \
            -o "$tmp/$name.$mode" >"$tmp/$name.$mode.build" 2>&1
        bounded "$tmp/$name.$mode" >"$tmp/$name.$mode.out"
        diff -u "$tmp/$name.interp" "$tmp/$name.$mode.out"
    done
done

# Removing the synthesized compound operator node must keep the original
# error anchor: the index position for an element, assignment for a local.
for target in local index; do
    if [ "$target" = local ]; then
        declaration='var value: int = 8'
        place='value'
    else
        declaration='var values: [int; 1] = [8]'
        place='values[0]'
    fi
    cat >"$tmp/$target.b" <<CASE
fn main() {
    $declaration
    $place /= 0
}
CASE
    bounded ./build/beansc build "$tmp/$target.b" \
        -o "$tmp/$target.native" >"$tmp/$target.build" 2>&1
    set +e
    bounded ./build/beansc run "$tmp/$target.b" >"$tmp/$target.interp" 2>&1
    interpreted=$?
    bounded "$tmp/$target.native" >"$tmp/$target.native.out" 2>&1
    native=$?
    set -e
    test "$interpreted" -eq 3
    test "$native" -eq 3
    grep 'runtime panic at .*divide by zero' "$tmp/$target.interp" >"$tmp/$target.interp.panic"
    grep 'runtime panic at .*divide by zero' "$tmp/$target.native.out" >"$tmp/$target.native.panic"
    diff -u "$tmp/$target.native.panic" "$tmp/$target.interp.panic"
done

echo "interpreter execution checks passed"
