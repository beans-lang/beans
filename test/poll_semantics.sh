#!/usr/bin/env bash
# Event-loop semantics, ported in spirit from libuv and mio: modify visible
# to the very next wait, removal honored by the next batch, cross-thread
# wake in both loop states, hangup delivered with its buffered bytes,
# timeout floors, the fd-reuse ABA, and quiet-crowd fairness. All pinned as
# derived facts in test/cases/poll_semantics.out, identical in both backends.
#
# The ordinary interpreter/native checks stay small. A separate native gate
# below proves the required 10,000 idle plus 100 active sockets.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-poll-semantics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

# The scale gate needs two descriptors per UDP socket on some hosts plus
# runtime headroom. Failure to raise this is visible in the golden diff.
ulimit -n 32768 2>/dev/null || true

echo "checking loop semantics in the interpreter"
"$beansc" run test/cases/poll_semantics.b >"$tmp/interp"
diff -u test/cases/poll_semantics.out "$tmp/interp"

echo "checking loop semantics in the native build"
"$beansc" build test/cases/poll_semantics.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/poll_semantics.out "$tmp/native.out"

echo "checking 10,000 idle sockets do not starve 100 active sockets"
POLL_SCALE_IDLE=10000 "$tmp/native" >"$tmp/scale.out"
diff -u test/cases/poll_semantics.out "$tmp/scale.out"

echo "checking loop semantics under an EINTR storm (failpoints)"
BEANS_SOCK_FAILPOINTS=4242:3:eintr "$tmp/native" >"$tmp/eintr.out"
diff -u test/cases/poll_semantics.out "$tmp/eintr.out"

echo "ok poll semantics: modify, remove, wake, hangup, timeouts, ABA, fairness, cancellation"
