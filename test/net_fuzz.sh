#!/usr/bin/env bash
# The socket and poller fuzz harness.
#
#   test/net_fuzz.sh smoke   # pinned seeds, both fuzzers, both backends
#   test/net_fuzz.sh run     # NET_FUZZ_* env vars pick the session
#   test/net_fuzz.sh soak    # wall-clock soak; NET_FUZZ_SECONDS bounds it
#
# Every case is reproducible from its seed: the drivers are seeded splitmix64
# generators (test/cases/sock_fuzz.b, test/cases/poll_fuzz.b), and the
# failpoint lane makes the runtime inject deterministic syscall failures
# from the same seed (BEANS_SOCK_FAILPOINTS=<seed>:<rate>[:eintr]).
#
# Replay one case exactly as the harness ran it:
#   ./build/beansc run test/cases/sock_fuzz.b -- <seed> <ops>
#   BEANS_SOCK_FAILPOINTS=<seed>:5 <native> <seed> <ops>
# BEANS_SOCK_FAILPOINTS_LOG=1 names every injected failure and its draw
# index on stderr.
#
# Env (run/soak): NET_FUZZ_START (first seed, default 1), NET_FUZZ_SEEDS
# (seed count, default 5), NET_FUZZ_OPS (ops per case, default 800),
# NET_FUZZ_SECONDS (soak budget, default 24 hours), POLL_SCALE_IDLE
# (soak-lane poller population, default 10,000 there, 400 elsewhere).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-net-fuzz.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

mode=${1:-smoke}
start=${NET_FUZZ_START:-1}
seeds=${NET_FUZZ_SEEDS:-5}
ops=${NET_FUZZ_OPS:-800}
soak_seconds=${NET_FUZZ_SECONDS:-86400}

ulimit -n 32768 2>/dev/null || true

echo "building the fuzz drivers"
# Report a build failure rather than dying silently under `set -e`: a soak
# that ends one line into its log with no reason is a soak nobody trusts.
build_driver() {
    local name=$1
    "$beansc" build "test/cases/$name.b" -o "$tmp/$name" >"$tmp/$name.build" 2>&1 || {
        echo "could not build the $name driver:" >&2
        cat "$tmp/$name.build" >&2
        exit 1
    }
}
for driver in sock_fuzz poll_fuzz http_fuzz compress_fuzz websocket_fuzz http2_fuzz; do
    build_driver "$driver"
done
if [[ "$mode" == "soak" ]]; then
    build_driver poll_semantics
fi

fail() {
    echo "net fuzz FAILED: $*" >&2
    echo "replay: see the command above; the seed and ops are in its arguments" >&2
    exit 1
}

# One case: a seed through one driver, clean and under mixed failpoints.
case_native() {
    local driver=$1 seed=$2 case_ops=$3
    "$tmp/$driver" "$seed" "$case_ops" >"$tmp/out" 2>&1 ||
        { cat "$tmp/out" >&2; fail "$driver seed=$seed ops=$case_ops (clean)"; }
    grep -q "^ok $driver" "$tmp/out" ||
        { cat "$tmp/out" >&2; fail "$driver seed=$seed missing ok line"; }
    BEANS_SOCK_FAILPOINTS="$seed:5" "$tmp/$driver" "$seed" "$case_ops" >"$tmp/out" 2>&1 ||
        { cat "$tmp/out" >&2; fail "$driver seed=$seed ops=$case_ops (failpoints $seed:5)"; }
    grep -q "^ok $driver" "$tmp/out" ||
        { cat "$tmp/out" >&2; fail "$driver seed=$seed failpoint lane missing ok line"; }
}

case_interp() {
    local driver=$1 seed=$2 case_ops=$3
    "$beansc" run "test/cases/$driver.b" -- "$seed" "$case_ops" >"$tmp/out" 2>&1 ||
        { cat "$tmp/out" >&2; fail "$driver seed=$seed (interpreter)"; }
    grep -q "^ok $driver" "$tmp/out" ||
        { cat "$tmp/out" >&2; fail "$driver seed=$seed interpreter missing ok line"; }
}

if [[ "$mode" == smoke ]]; then
    # Pinned and quick: the suite's own gate. Two seeds native, one seed
    # interpreted, both drivers, plus one failpoint-heavy lane each.
    for seed in 1 2; do
        echo "sock_fuzz seed=$seed (native, clean + failpoints)"
        case_native sock_fuzz "$seed" 500
        echo "poll_fuzz seed=$seed (native, clean + failpoints)"
        case_native poll_fuzz "$seed" 500
    done
    echo "sock_fuzz seed=3 (interpreter)"
    case_interp sock_fuzz 3 300
    echo "poll_fuzz seed=3 (interpreter)"
    case_interp poll_fuzz 3 300
elif [[ "$mode" == run ]]; then
    for ((seed = start; seed < start + seeds; seed++)); do
        echo "sock_fuzz seed=$seed ops=$ops"
        case_native sock_fuzz "$seed" "$ops"
        echo "poll_fuzz seed=$seed ops=$ops"
        case_native poll_fuzz "$seed" "$ops"
        echo "http_fuzz seed=$seed cases=$ops"
        "$tmp/http_fuzz" "$seed" "$ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "http_fuzz seed=$seed"; }
        grep -q "^ok http_fuzz" "$tmp/out" ||
            { cat "$tmp/out" >&2; fail "http_fuzz seed=$seed missing ok line"; }
        echo "compress_fuzz seed=$seed cases=$ops"
        "$tmp/compress_fuzz" "$seed" "$ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "compress_fuzz seed=$seed"; }
        grep -q "^ok compress_fuzz" "$tmp/out" ||
            { cat "$tmp/out" >&2; fail "compress_fuzz seed=$seed missing ok line"; }
        # The websocket lane opens a socket pair per round, so it runs a
        # tenth of the ops the buffer-only fuzzers do.
        ws_ops=$(( ops / 10 ))
        [ "$ws_ops" -lt 20 ] && ws_ops=20
        echo "websocket_fuzz seed=$seed rounds=$ws_ops"
        "$tmp/websocket_fuzz" "$seed" "$ws_ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "websocket_fuzz seed=$seed"; }
        grep -q "^ok websocket_fuzz" "$tmp/out" ||
            { cat "$tmp/out" >&2; fail "websocket_fuzz seed=$seed missing ok line"; }
        # The h2 lane opens two full sessions per round, so it runs fewer
        # still than the websocket one.
        h2_ops=$(( ops / 20 ))
        [ "$h2_ops" -lt 10 ] && h2_ops=10
        echo "http2_fuzz seed=$seed rounds=$h2_ops"
        "$tmp/http2_fuzz" "$seed" "$h2_ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "http2_fuzz seed=$seed"; }
        grep -q "^ok http2_fuzz" "$tmp/out" ||
            { cat "$tmp/out" >&2; fail "http2_fuzz seed=$seed missing ok line"; }
    done
elif [[ "$mode" == soak ]]; then
    # Wall-clock bounded; every iteration is still fully seeded, so any
    # failure names the seed that reproduces it. The poller lane runs its
    # scale section at soak size.
    export POLL_SCALE_IDLE=${POLL_SCALE_IDLE:-10000}
    "$tmp/poll_semantics" >"$tmp/poll_scale.out"
    diff -u test/cases/poll_semantics.out "$tmp/poll_scale.out" ||
        fail "10,000-idle/100-active poll scale gate"
    deadline=$(( $(date +%s) + soak_seconds ))
    seed=$start
    cases=0
    while (( $(date +%s) < deadline )); do
        case_native sock_fuzz "$seed" "$ops"
        case_native poll_fuzz "$seed" "$ops"
        "$tmp/http_fuzz" "$seed" "$ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "http_fuzz seed=$seed"; }
        "$tmp/compress_fuzz" "$seed" "$ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "compress_fuzz seed=$seed"; }
        ws_ops=$(( ops / 10 ))
        [ "$ws_ops" -lt 20 ] && ws_ops=20
        "$tmp/websocket_fuzz" "$seed" "$ws_ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "websocket_fuzz seed=$seed"; }
        h2_ops=$(( ops / 20 ))
        [ "$h2_ops" -lt 10 ] && h2_ops=10
        "$tmp/http2_fuzz" "$seed" "$h2_ops" >"$tmp/out" 2>&1 ||
            { cat "$tmp/out" >&2; fail "http2_fuzz seed=$seed"; }
        seed=$((seed + 1))
        cases=$((cases + 6))
    done
    echo "soak finished: $cases cases, seeds $start..$((seed - 1)), ${soak_seconds}s budget"
else
    echo "usage: test/net_fuzz.sh [smoke|run|soak]" >&2
    exit 2
fi

echo "ok net fuzz ($mode): seeded sequences, failpoint lanes, fd census, readiness oracle"
