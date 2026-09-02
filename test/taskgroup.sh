#!/usr/bin/env bash
# TaskGroup<T> (spec/CONCURRENCY.md, F3): dynamic fleets on the fiber
# scheduler. The differential case pins delivery order, spawn-order
# wait_all, panic-as-err delivery, reuse after draining, and cancel_all —
# byte-identical on both engines. The walls keep the group scope-bound
# exactly as a Brew handle is, and a fleet nobody can wake lands in the
# deadlock report instead of hanging.
set -euo pipefail

# macOS runners ship no GNU timeout; stand in for it when absent. The
# stand-in reports 137 (SIGKILL) where GNU prints 124 — every use here
# only cares that a hang cannot pass, and neither code ever matches an
# expected exit.
if ! command -v timeout >/dev/null 2>&1; then
timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local dog=$!
    local status=0
    wait "$pid" || status=$?
    kill "$dog" 2>/dev/null
    wait "$dog" 2>/dev/null || true
    return "$status"
}
fi

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-taskgroup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking TaskGroup: completion order, spawn-order wait_all, panic delivery, reuse, cancel"
timeout 60 ./build/beansc run test/cases/taskgroup.b >"$tmp/interp"
./build/beansc build test/cases/taskgroup.b -o "$tmp/native" >"$tmp/build" 2>&1
timeout 60 "$tmp/native" >"$tmp/native.out"
diff -u test/cases/taskgroup.out "$tmp/interp"
diff -u test/cases/taskgroup.out "$tmp/native.out"

echo "checking the group walls refuse with named messages"
cat >"$tmp/walls.b" <<'BEANS'
fn work(a: int) -> int { return a }

class Holder {
    fleet: TaskGroup<int>
}

fn hand(group: TaskGroup<int>) -> int { return 0 }

fn main() {
    let group: TaskGroup<int> = new TaskGroup<int>()
    let moved: TaskGroup<int> = move group
    let closer: fn() -> unit = fn() {
        group.cancel_all()
    }
    let groups: List<TaskGroup<int>> = []
    group.brew(7)
    if work(1) == 1 {
        let inner: TaskGroup<int> = new TaskGroup<int>()
    }
}
BEANS
if ./build/beansc check "$tmp/walls.b" >"$tmp/walls.log" 2>&1; then
    echo "the group walls accepted misuse" >&2
    cat "$tmp/walls.log" >&2
    exit 1
fi
expect_wall() { # <fragment>
    grep -q "$1" "$tmp/walls.log" || {
        echo "missing wall: $1" >&2
        cat "$tmp/walls.log" >&2
        exit 1
    }
}
expect_wall "TaskGroup cannot appear in a signature or field"
expect_wall "cannot take a TaskGroup"
expect_wall "closure cannot capture TaskGroup"
expect_wall "TaskGroup cannot ride inside another type"
expect_wall "group.brew starts a user function or method on a child fiber"
expect_wall "inside a nested block is not ready yet"
# Whoever lands here got here from the brew wall, so the message has to say
# that moving the group out does not mean moving the brew out with it (#32).
expect_wall "group.brew(...) on it stays legal at any depth"

echo "checking a fleet nobody can wake reports a deadlock"
cat >"$tmp/dead.b" <<'BEANS'
import std.io

fn stuck(gate: Gate) -> int {
    gate.wait()
    return 1
}

fn main() {
    io.println("about to deadlock")
    let shut: Gate = new Gate()
    let group: TaskGroup<int> = new TaskGroup<int>()
    group.brew(stuck(shut))
    match group.next() {
        some(outcome) => { io.println("bad delivery") }
        none => { io.println("bad none") }
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

echo "ok TaskGroup: delivery order, walls, panic delivery, deadlock report"
