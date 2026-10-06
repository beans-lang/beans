#!/usr/bin/env bash
# Changes to host value storage and control-flow results must preserve the
# represented program's copies, aliases, cleanup, weak references and returns.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-interpreter-values.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

source=test/cases/interpreter_values.b
expected=test/cases/interpreter_values.out
"$beansc" run "$source" >"$tmp/interp"
diff -u "$expected" "$tmp/interp"
for mode in debug release; do
    if [ "$mode" = release ]; then
        "$beansc" build --release "$source" -o "$tmp/$mode" >"$tmp/build" 2>&1
    else
        "$beansc" build "$source" -o "$tmp/$mode" >"$tmp/build" 2>&1
    fi
    "$tmp/$mode" >"$tmp/$mode.out"
    diff -u "$expected" "$tmp/$mode.out"
done

echo "ok interpreter scalar/compound values, returns, copies, aliases, weak revival and release order"

# An expression that panics never supplies its declared payload. Exercise
# dependent reflection, assignment and union-initialization paths both under
# contained cleanup and as an ordinary process-terminating failure.
source=test/cases/interpreter_values_failures.b
expected=test/cases/interpreter_values_failures.out
for leg in interp debug release; do
    if [ "$leg" = debug ]; then
        "$beansc" build "$source" -o "$tmp/failures-$leg" >"$tmp/build" 2>&1
    elif [ "$leg" = release ]; then
        "$beansc" build --release "$source" -o "$tmp/failures-$leg" >"$tmp/build" 2>&1
    fi
    : >"$tmp/failures-$leg.out"
    for mode in cast union literal slice compound; do
        if [ "$leg" = interp ]; then
            "$beansc" run "$source" -- "$mode" >>"$tmp/failures-$leg.out"
        else
            "$tmp/failures-$leg" "$mode" >>"$tmp/failures-$leg.out"
        fi

        status=0
        if [ "$leg" = interp ]; then
            "$beansc" run "$source" -- "$mode" uncontained \
                >"$tmp/panic.out" 2>"$tmp/panic.err" || status=$?
        else
            "$tmp/failures-$leg" "$mode" uncontained \
                >"$tmp/panic.out" 2>"$tmp/panic.err" || status=$?
        fi
        test "$status" -eq 3
        test ! -s "$tmp/panic.out"
        if [ "$mode" = cast ]; then
            printf '%s\n' 'runtime panic at 17:43: original reflect failure' >"$tmp/panic.expected"
        elif [ "$mode" = compound ]; then
            printf '%s\n' 'runtime panic at 66:11: divide by zero' >"$tmp/panic.expected"
        else
            printf '%s\n' 'runtime panic at 18:38: original array failure' >"$tmp/panic.expected"
        fi
        diff -u "$tmp/panic.expected" "$tmp/panic.err"
    done
    diff -u "$expected" "$tmp/failures-$leg.out"
done

echo "ok failed typed expressions preserve original panic and contained cleanup"
