#!/usr/bin/env bash
set -euo pipefail

# A worker's fiber pool is bounded: it keeps a fixed number of finished fibers
# for stack reuse and releases the rest, so a burst of thousands of fibers
# hands its stacks back when the burst ends. test/cases/fiber_storm.b holds
# 10000 fibers alive at once, then joins them; this driver samples the resident
# set at the high-water and after the join and asserts the set falls back — the
# stacks were released, not pooled without bound. It runs the burst twice and
# checks the second is not slower than the first: the warm pool must still be
# there to reuse.
#
# Both backends run real fibers, so both must return the stacks. The set does
# not fall all the way to baseline — a burst leaves the small-object pool grown
# (the interpreter, which boxes every value, keeps much more) — but that is the
# object pool, not the fiber stacks this gate is about, so the test asserts a
# large fall from the high-water, not a return to zero.

cd "$(dirname "$0")/.."
BEANSC=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fiberstack.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if ! command -v ps >/dev/null 2>&1; then
    echo "fiber_stacks: ps not found — cannot sample resident memory" >&2
    exit 1
fi

prog=test/cases/fiber_storm.b
"$BEANSC" build "$prog" -o "$tmp/storm-native" >"$tmp/build.log" 2>&1

# drive <cmd...> : run one backend through baseline, two bursts, sampling RSS
# (KiB) and a monotonic timestamp at each marker. Writes five
# "<rss> <seconds>" pairs, one per line.
drive() {
    local work
    work=$(mktemp -d "$tmp/run.XXXXXX")
    mkfifo "$work/in"
    : >"$work/err"
    "$@" <"$work/in" 2>"$work/err" >/dev/null &
    local pid=$!
    exec 8>"$work/in"
    local m tries
    for m in baseline parked-1 joined-1 parked-2 joined-2; do
        tries=0
        until grep -q "phase $m" "$work/err" 2>/dev/null; do
            if ! kill -0 "$pid" 2>/dev/null; then
                exec 8>&-
                echo "fiber_stacks: process exited before marker '$m'" >&2
                return 1
            fi
            tries=$((tries + 1))
            if [ "$tries" -gt 8000 ]; then
                exec 8>&-; kill "$pid" 2>/dev/null || true
                echo "fiber_stacks: timed out waiting for '$m'" >&2
                return 1
            fi
            sleep 0.01
        done
        echo "$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ') $(date +%s.%N)"
        echo >&8
    done
    exec 8>&-
    wait "$pid" 2>/dev/null || true
}

check() {
    local label=$1
    shift
    # five lines: baseline, parked-1, joined-1, parked-2, joined-2
    local base_r base_t p1_r p1_t j1_r j1_t p2_r p2_t j2_r j2_t
    { read -r base_r base_t
      read -r p1_r p1_t
      read -r j1_r j1_t
      read -r p2_r p2_t
      read -r j2_r j2_t
    } < <("$@")

    if [ -z "${j2_r:-}" ]; then
        echo "fiber_stacks: $label produced no samples" >&2
        exit 1
    fi

    local grew1=$((p1_r - base_r))
    echo "  $label: base=${base_r}K high-water=${p1_r}K after-join=${j1_r}K (grew ${grew1}K)"

    # The storm must have really put thousands of stacks resident.
    if [ "$grew1" -lt 80000 ]; then
        echo "fiber_stacks: $label storm never grew — got ${grew1}K, expected the 10k stacks" >&2
        exit 1
    fi
    # After the join, resident must fall well below the high-water: the stacks
    # past the pool bound were released. 70% is a wide margin — native returns
    # ~90%, the interpreter ~55%; an unbounded pool would return almost none.
    local cap=$((p1_r * 7 / 10))
    if [ "$j1_r" -ge "$cap" ]; then
        echo "fiber_stacks: $label did not release its stacks — after-join ${j1_r}K still near high-water ${p1_r}K" >&2
        exit 1
    fi

    # The second burst must not be slower than the first by more than the noise
    # of a shared box: the pool the first burst warmed must still be reusable.
    local d1 d2
    d1=$(awk "BEGIN{printf \"%d\", ($j1_t - $p1_t) * 1000}")
    d2=$(awk "BEGIN{printf \"%d\", ($j2_t - $p2_t) * 1000}")
    echo "  $label: first burst join ${d1}ms, second ${d2}ms"
    local budget=$((d1 * 2 + 50))   # 2x plus a floor for sub-millisecond bursts
    if [ "$d2" -gt "$budget" ]; then
        echo "fiber_stacks: $label second burst slower than the first (${d2}ms vs ${d1}ms) — the warm pool did not survive" >&2
        exit 1
    fi
}

echo "checking a fiber storm returns its stacks (native)"
check "native" drive "$tmp/storm-native"
echo "checking a fiber storm returns its stacks (interpreter)"
check "interpreter" drive "$BEANSC" run "$prog"
echo "ok fiber stacks: a 10k-fiber storm hands its stacks back, and a warm pool keeps the next one fast"
