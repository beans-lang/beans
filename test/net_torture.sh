#!/usr/bin/env bash
# The nasty-condition matrix for std.net: partial IO under load, SO_ERROR
# refusal, reset mid-write, half-close, zero-length and truncated datagrams,
# resolver candidate order, backlog overflow, and multicast membership —
# each printed as a derived fact and pinned in test/cases/net_torture.out.
# The same golden must hold in the interpreter, in the native build, and in
# the native build under an EINTR failpoint storm — which is what turns
# "every blocking call retries EINTR" from a comment into a contract.
# (Close-on-exec inheritance is pinned by test/net.sh.)
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-net-torture.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

echo "checking the matrix in the interpreter"
"$beansc" run test/cases/net_torture.b >"$tmp/interp"
diff -u test/cases/net_torture.out "$tmp/interp"

echo "checking the matrix in the native build"
"$beansc" build test/cases/net_torture.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/net_torture.out "$tmp/native.out"

echo "checking the matrix under an EINTR storm (failpoints)"
BEANS_SOCK_FAILPOINTS=1337:3:eintr "$tmp/native" >"$tmp/eintr.out"
diff -u test/cases/net_torture.out "$tmp/eintr.out"
BEANS_SOCK_FAILPOINTS=97:2:eintr "$beansc" run test/cases/net_torture.b >"$tmp/eintr.interp"
diff -u test/cases/net_torture.out "$tmp/eintr.interp"

echo "ok net torture: partial IO, refusal, reset, half-close, datagrams, backlog, multicast, EINTR storm"
