#!/usr/bin/env bash
# Gate (spec/CONCURRENCY.md, F3): a sticky broadcast flag on the fiber
# scheduler. The differential case pins both engines byte-for-byte — two
# watchers parked on one gate waking FIFO from a sibling fiber's open, the
# sticky wait-after-open, and a fiber parked while an OS thread fires the
# open. The deadlock probe proves a wait at a gate nothing will ever open
# reports and exits instead of hanging.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-gate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking Gate: broadcast wake, sticky open, cross-thread open"
./build/beansc run test/cases/gate.b >"$tmp/interp"
./build/beansc build test/cases/gate.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/gate.out "$tmp/interp"
diff -u test/cases/gate.out "$tmp/native.out"

echo "checking a wait nobody will open reports a deadlock instead of hanging"
cat >"$tmp/dead.b" <<'BEANS'
import std.io

fn forever(gate: Gate) -> int {
    gate.wait()
    return 1
}

fn main() {
    io.println("about to deadlock")
    let gate: Gate = new Gate()
    let h: Brew<int> = brew forever(gate)
    match h.join() {
        ok(value) => { io.println("bad {value}") }
        err(error) => { io.println("bad err") }
    }
}
BEANS
expect_deadlock() { # <command...>
    set +e
    "$@" >"$tmp/dead.out" 2>"$tmp/dead.err"
    local status=$?
    set -e
    if [ "$status" -ne 3 ]; then
        echo "deadlock should exit 3, got $status" >&2
        cat "$tmp/dead.err" >&2
        exit 1
    fi
    grep -q "deadlock: every fiber is parked and nothing can wake them" \
        "$tmp/dead.err"
    grep -q "fiber 'forever' parked" "$tmp/dead.err"
    grep -q "fiber 'main' parked" "$tmp/dead.err"
}
expect_deadlock timeout 30 ./build/beansc run "$tmp/dead.b"
./build/beansc build "$tmp/dead.b" -o "$tmp/dead" >/dev/null 2>&1
expect_deadlock timeout 30 "$tmp/dead"

echo "ok Gate: broadcast wake order, sticky open, cross-thread open, deadlock report"
