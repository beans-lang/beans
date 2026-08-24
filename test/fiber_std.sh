#!/usr/bin/env bash
# std on fibers (spec/CONCURRENCY.md, F3): channels, sleep, and thread.join
# park the calling fiber instead of blocking its worker. The differential
# case pins the semantics on both engines at once — a same-worker channel
# ping-pong (an instant thread deadlock before fiber-aware channels),
# deadline-ordered sleeps, close waking a parked receiver, a closed-channel
# send panicking contained to its fiber, and a sibling fiber running while
# another fiber joins an OS thread. The parked-receiver-then-join shape is
# also the exact scenario that once deadlocked the interpreter's brew state
# lock; byte-identical output here is the regression gate for it.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fiber-std.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking std parks fibers: channels, sleep, thread join"
./build/beansc run test/cases/fiber_std.b >"$tmp/interp"
./build/beansc build test/cases/fiber_std.b -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/fiber_std.out "$tmp/interp"
diff -u test/cases/fiber_std.out "$tmp/native.out"

echo "checking a hopeless park reports a deadlock instead of hanging"
cat >"$tmp/dead.b" <<'BEANS'
import std.io

fn stuck(ch: Channel<int>) -> int {
    match ch.receive() {
        some(value) => { return value }
        none => { return -1 }
    }
}

fn main() {
    io.println("about to deadlock")
    let ch: Channel<int> = new Channel(1)
    let h: Brew<int> = brew stuck(ch)
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
    grep -q "fiber 'stuck' parked" "$tmp/dead.err"
    grep -q "fiber 'main' parked" "$tmp/dead.err"
}
expect_deadlock timeout 30 ./build/beansc run "$tmp/dead.b"
./build/beansc build "$tmp/dead.b" -o "$tmp/dead" >/dev/null 2>&1
expect_deadlock timeout 30 "$tmp/dead"

echo "ok std on fibers: channel handoff, timer order, contained close panic, parking joins, deadlock report"
