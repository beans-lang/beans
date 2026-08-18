#!/usr/bin/env bash
# Event-loop semantics, ported in spirit from libuv and mio: modify visible
# to the very next wait, removal honored by the next batch, cross-thread
# wake in both loop states, hangup delivered with its buffered bytes,
# timeout floors, the fd-reuse ABA, quiet-crowd fairness, and async
# cancellation deregistering its readiness interest. All pinned as derived
# facts in test/cases/poll_semantics.out, identical in both backends.
#
# The scale section defaults to 400 idle sockets so the suite stays inside
# default fd limits; the fuzz soak lane raises POLL_SCALE_IDLE instead.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-poll-semantics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

# The scale section needs headroom over the default soft limit on macOS.
ulimit -n 4096 2>/dev/null || true

echo "checking loop semantics in the interpreter"
"$beansc" run test/cases/poll_semantics.b >"$tmp/interp"
diff -u test/cases/poll_semantics.out "$tmp/interp"

echo "checking loop semantics in the native build"
"$beansc" build test/cases/poll_semantics.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/poll_semantics.out "$tmp/native.out"

echo "checking loop semantics under an EINTR storm (failpoints)"
BEANS_SOCK_FAILPOINTS=4242:3:eintr "$tmp/native" >"$tmp/eintr.out"
diff -u test/cases/poll_semantics.out "$tmp/eintr.out"

echo "ok poll semantics: modify, remove, wake, hangup, timeouts, ABA, fairness, cancellation"
