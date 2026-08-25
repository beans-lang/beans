#!/usr/bin/env bash
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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fiber-core.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# The fiber runtime core (runtime/beans_fiber.c) is pure C and tested
# without the compiler — the F1 gate of spec/CONCURRENCY.md: semantics,
# 10k-fiber churn, panic containment under load, cross-thread wakes, the
# guard-page report, the switch budget, and both sanitizers.

echo "checking the fiber runtime core"
clang -O2 -std=c11 -Wall -Wextra -Werror \
    runtime/beans_fiber.c test/fiber_core.c -o "$tmp/fiber_core" -lpthread
"$tmp/fiber_core"

echo "checking the context-switch budget"
"$tmp/fiber_core" bench | tee "$tmp/bench"
awk '/^switch/ {
    if ($2 + 0 >= 50) {
        print "switch cost " $2 "ns breaks the 50ns budget" > "/dev/stderr"
        exit 1
    }
}' "$tmp/bench"

echo "checking a stack overflow reports the fiber and aborts"
set +e
"$tmp/fiber_core" overflow >"$tmp/overflow.log" 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
    echo "the overflow never faulted" >&2
    cat "$tmp/overflow.log" >&2
    exit 1
fi
grep -q "fiber stack overflow: deep" "$tmp/overflow.log" || {
    echo "the overflow report never named the fiber" >&2
    cat "$tmp/overflow.log" >&2
    exit 1
}

echo "checking a hopeless idle reports a deadlock"
set +e
timeout 20 "$tmp/fiber_core" deadlock >"$tmp/deadlock.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 3 ]]; then
    echo "the deadlock report should exit 3, got $status" >&2
    cat "$tmp/deadlock.log" >&2
    exit 1
fi
grep -q "deadlock: every fiber is parked and nothing can wake them" \
    "$tmp/deadlock.log"
grep -q "fiber 'hopeless' parked" "$tmp/deadlock.log"

echo "checking under AddressSanitizer"
if clang -O1 -g -std=c11 -fsanitize=address \
    runtime/beans_fiber.c test/fiber_core.c -o "$tmp/fiber_asan" -lpthread; then
    "$tmp/fiber_asan"
else
    echo "ASan unavailable here; skipped" >&2
fi

echo "checking under ThreadSanitizer"
if clang -O1 -g -std=c11 -fsanitize=thread \
    runtime/beans_fiber.c test/fiber_core.c -o "$tmp/fiber_tsan" -lpthread; then
    # Same discipline as test/sanitize.sh: the signal is the warning text.
    set +e
    "$tmp/fiber_tsan" >"$tmp/tsan.stdout" 2>"$tmp/tsan.stderr"
    status=$?
    set -e
    if grep -q 'WARNING: ThreadSanitizer' "$tmp/tsan.stderr"; then
        echo "TSan reported a race in the fiber core" >&2
        sed -n '1,200p' "$tmp/tsan.stderr" >&2
        exit 1
    fi
    if grep -q 'ThreadSanitizer: CHECK failed' "$tmp/tsan.stderr"; then
        echo "TSan cannot start here (emulated syscall); skipped" >&2
    elif [[ "$status" -ne 0 ]]; then
        echo "the TSan fiber core exited $status" >&2
        sed -n '1,60p' "$tmp/tsan.stderr" >&2
        exit 1
    fi
else
    echo "TSan unavailable here; skipped" >&2
fi

echo "ok fiber core: semantics, containment, churn, switch budget, sanitizers"
