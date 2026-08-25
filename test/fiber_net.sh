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

echo "ok netpoller: fiber TCP on one worker, both engines identical, deadlines hold"
