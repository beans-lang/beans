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
# NET_FUZZ_SECONDS (soak budget, default 300), POLL_SCALE_IDLE (soak-lane
# poller population, default 4000 there, 400 elsewhere).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-net-fuzz.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

mode=${1:-smoke}
start=${NET_FUZZ_START:-1}
seeds=${NET_FUZZ_SEEDS:-5}
ops=${NET_FUZZ_OPS:-800}
soak_seconds=${NET_FUZZ_SECONDS:-300}

ulimit -n 4096 2>/dev/null || true

echo "building the fuzz drivers"
"$beansc" build test/cases/sock_fuzz.b -o "$tmp/sock_fuzz" >/dev/null 2>&1
"$beansc" build test/cases/poll_fuzz.b -o "$tmp/poll_fuzz" >/dev/null 2>&1

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
    done
elif [[ "$mode" == soak ]]; then
    # Wall-clock bounded; every iteration is still fully seeded, so any
    # failure names the seed that reproduces it. The poller lane runs its
    # scale section at soak size.
    export POLL_SCALE_IDLE=${POLL_SCALE_IDLE:-4000}
    deadline=$(( $(date +%s) + soak_seconds ))
    seed=$start
    cases=0
    while (( $(date +%s) < deadline )); do
        case_native sock_fuzz "$seed" "$ops"
        case_native poll_fuzz "$seed" "$ops"
        seed=$((seed + 1))
        cases=$((cases + 2))
    done
    echo "soak finished: $cases cases, seeds $start..$((seed - 1)), ${soak_seconds}s budget"
else
    echo "usage: test/net_fuzz.sh [smoke|run|soak]" >&2
    exit 2
fi

echo "ok net fuzz ($mode): seeded sequences, failpoint lanes, fd census, readiness oracle"
