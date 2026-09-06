#!/usr/bin/env bash
# The netpoller (spec/CONCURRENCY.md, F3): net waits park fibers in their
# worker's kernel poller — kqueue here, epoll on Linux — instead of
# blocking the thread. The differential case runs both TCP ends as fibers
# of one worker (impossible before the netpoller: accept would block the
# only thread) and demands byte-identical output from both engines. The
# probe case proves a socket deadline still fires for a parked fiber and
# answers in bounded time.
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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fiber-net.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking both TCP ends as fibers of one worker"
timeout 60 ./build/beansc run test/cases/fiber_net.b >"$tmp/interp"
./build/beansc build test/cases/fiber_net.b -o "$tmp/native" >"$tmp/build" 2>&1
timeout 60 "$tmp/native" >"$tmp/native.out"
diff -u test/cases/fiber_net.out "$tmp/interp"
diff -u test/cases/fiber_net.out "$tmp/native.out"

echo "checking a parked fiber still honours the accept deadline"
cat >"$tmp/deadline.b" <<'BEANS'
import std.io
import std.net

fn lonely(listener: net.TcpListener) -> string {
    match listener.accept_timeout(250) {
        ok(session) => { return "unexpected guest" }
        err(error) => { return error.kind }
    }
}

fn watch() -> Result<int> {
    let listener: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
    let h: Brew<string> = brew lonely(listener)
    match h.join() {
        ok(kind) => { io.println("accept gave {kind}") }
        err(error) => { io.println("fiber failed") }
    }
    return ok(0)
}

fn main() {
    match watch() {
        ok(value) => {}
        err(error) => { io.println("bind failed") }
    }
}
BEANS
run_deadline() { # <command...>
    local started finished
    started=$(date +%s)
    timeout 30 "$@" >"$tmp/deadline.out"
    finished=$(date +%s)
    grep -q "accept gave timeout" "$tmp/deadline.out"
    # 250ms deadline: anything over 10s means the park never timed out
    if [ $((finished - started)) -gt 10 ]; then
        echo "the deadline wait took $((finished - started))s" >&2
        exit 1
    fi
}
run_deadline ./build/beansc run "$tmp/deadline.b"
./build/beansc build "$tmp/deadline.b" -o "$tmp/deadline" >/dev/null 2>&1
run_deadline "$tmp/deadline"

# Many parked reads with interleaved deadlines, plus the stale-entry shape:
# the single accept-deadline probe above only ever puts one entry in the
# sleeper heap. This one fills the heap out of deadline order and asserts the
# timeouts fire in deadline order (ids 2,4,5,1,3 for 30,50,70,90,110 ms), and
# that a fiber signalled before its deadline and re-parked with a new one times
# out at the new deadline while the abandoned entry does not fire at it. Both
# engines run the one fiber runtime, so both must print the same lines; a
# broken sleeper heap reorders them or misses a timeout.
echo "checking interleaved and re-armed fiber read deadlines in both backends"
started=$(date +%s)
timeout 30 ./build/beansc run test/cases/fiber_deadlines.b >"$tmp/dl-interp"
./build/beansc build test/cases/fiber_deadlines.b -o "$tmp/dl-native" >/dev/null 2>&1
timeout 30 "$tmp/dl-native" >"$tmp/dl-native.out"
finished=$(date +%s)
diff -u "$tmp/dl-interp" "$tmp/dl-native.out"
diff -u - "$tmp/dl-interp" <<'EXPECTED'
one: 1
many order: 24513
stale: 7
EXPECTED
# The whole run is well under a second when deadlines fire on time; the stale
# 300ms entry firing at the wrong fiber would show up as a hang toward it.
if [ $((finished - started)) -gt 8 ]; then
    echo "the deadline cases took $((finished - started))s — a deadline did not fire on time" >&2
    exit 1
fi

echo "ok netpoller: fiber TCP on one worker, both engines identical, deadlines hold"
