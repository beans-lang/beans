#!/usr/bin/env bash
# Borrowed list iteration: elements are read as borrows only when the
# binding cannot outlive its slot. The cases pin the hazards; the MIR
# greps pin that the safe loop really stopped retaining and that the
# mutating and capturing loops kept their per-element ownership.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-borrowed-iteration.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/borrowed_iteration.b >"$tmp/interp"
./build/beansc build test/cases/borrowed_iteration.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/borrowed_iteration.out "$tmp/interp"
diff -u test/cases/borrowed_iteration.out "$tmp/native.out"

# The MIR dump names a function by its canonical symbol, "<package>::<name>".
mir_body() {
    ./build/beansc mir test/cases/borrowed_iteration.b |
        awk -v name="main::$1" '
            $1 == "fn" && $2 == name { inside = 1; next }
            $1 == "fn" { inside = 0 }
            inside'
}

# safe_sum's element read borrows and its binding is never dropped
mir_body safe_sum | grep -q 'borrow-elided'
if mir_body safe_sum | grep -q 'drop_local item '; then
    echo "safe_sum still drops its borrowed binding" >&2
    exit 1
fi

# the loop that clears the list must keep an owned element
if mir_body mutation_during_iteration | grep -q 'borrow-elided'; then
    echo "mutation_during_iteration wrongly borrowed its binding" >&2
    exit 1
fi

# elements handed to closures must stay owned per iteration
if mir_body captured_bindings | grep -q 'borrow-elided'; then
    echo "captured_bindings wrongly borrowed its binding" >&2
    exit 1
fi
