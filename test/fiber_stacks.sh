#!/usr/bin/env bash
set -euo pipefail

# A worker's fiber pool is bounded: it keeps a fixed number of finished fibers
# for stack reuse and releases the rest, so a burst of thousands of fibers
# hands its stacks back when the burst ends. test/cases/fiber_storm.b holds a
# chain of fibers alive at once, then joins them; this driver samples the
# resident set at the high-water and after the join and asserts the stacks came
# back. It runs the burst twice and checks the second is not slower than the
# first: the warm pool must still be there to reuse.
#
# What one parked fiber costs, and why the numbers below are derived rather
# than observed. A fiber's stack is one mmap of BEANS_FIBER_DEFAULT_STACK
# (512 KiB) with MAP_NORESERVE and a guard page, and its pages commit only as
# the fiber touches them — that is the whole point of the reservation. A fiber
# that has run its entry and parked has touched its frame, and a touched byte
# commits a whole page, so `fibers × PAGE_SIZE` is a floor on what the storm
# put resident, and the join giving the stacks back means about that much
# leaves again. That is the only platform fact in this gate, and it is read
# from the platform (getconf PAGE_SIZE) rather than guessed: 4 KiB pages make
# it 40 MB for a 10k storm, 16 KiB pages make it 160 MB. Measured, the native
# leg returns 99% of exactly that figure and no more — 158992K of 160000K on
# macOS/arm64, 39740K of 40000K on Linux — which is what says the number is
# the right one. The interpreter returns far more (5.5 GB on Linux), because
# it also hands back what it allocated per fiber; the floor is a floor.
#
# The gate previously asserted `grew > 80000` KiB and `after-join < 70% of
# high-water`. The first was 16 KiB pages × 10k fibers ÷ 2 — a macOS number,
# and Linux failed it at a perfectly healthy 55.5 MB. The second was weaker
# than it looked in the other direction: it measured the fall against the
# absolute high-water, which carries the baseline, so it got easier as the
# baseline shrank, and a run that pooled half the stacks passed it.
#
# Both backends run real fibers, so both must return the stacks. Resident does
# not fall all the way to baseline — a burst leaves the small-object pool grown
# (the interpreter, which boxes every value, keeps much more) — but that is the
# object pool, not the fiber stacks this gate is about, so the fall is measured
# against the stacks the fibers must have cost, not against the high-water.

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

# The page is the unit a lazily-committed stack becomes resident in, so it is
# what a per-fiber cost is counted in. Asking the platform is the derivation;
# 4 KiB is the smallest page any target here has, so a platform that will not
# answer gets the most forgiving floor rather than a wrong one.
page=$(getconf PAGE_SIZE 2>/dev/null || true)
case "$page" in
    ''|*[!0-9]*)
        echo "fiber_stacks: getconf PAGE_SIZE gave '${page:-nothing}';" \
             "assuming 4096, so the stack floors below are as forgiving as" \
             "any supported platform allows" >&2
        page=4096
        ;;
esac

# drive <cmd...> : run one backend through baseline, two bursts, sampling RSS
# (KiB) and a monotonic timestamp at each marker. Writes five
# "<rss> <seconds>" pairs, one per line, then a sixth line
# "<fibers> <depth-1> <depth-2>" read back out of the program's own markers.
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
    # The program says how many fibers a storm is meant to hold and what depth
    # each chain actually reached. Both are needed: the count is the
    # expectation every floor below is derived from, and the depths are what
    # says the storm really built it.
    echo "$(sed -n 's/^fibers \([0-9]*\)$/\1/p' "$work/err" | head -1)" \
         "$(sed -n 's/^phase joined-1 \(-*[0-9]*\)$/\1/p' "$work/err" | head -1)" \
         "$(sed -n 's/^phase joined-2 \(-*[0-9]*\)$/\1/p' "$work/err" | head -1)"
}

check() {
    local label=$1
    shift
    # five lines: baseline, parked-1, joined-1, parked-2, joined-2; then the
    # program's own fiber count and the depth each chain reached
    local base_r base_t p1_r p1_t j1_r j1_t p2_r p2_t j2_r j2_t
    local fibers depth1 depth2
    { read -r base_r base_t
      read -r p1_r p1_t
      read -r j1_r j1_t
      read -r p2_r p2_t
      read -r j2_r j2_t
      read -r fibers depth1 depth2
    } < <("$@")

    if [ -z "${j2_r:-}" ]; then
        echo "fiber_stacks: $label produced no samples" >&2
        exit 1
    fi
    case "${fibers:-}" in
        ''|*[!0-9]*)
            echo "fiber_stacks: $label never said how many fibers a storm" \
                 "holds — test/cases/fiber_storm.b prints 'fibers <n>' and" \
                 "every expectation here is derived from it" >&2
            exit 1
            ;;
    esac

    # The storm actually allocated its stacks. Not a memory measurement: each
    # link of the chain parks the next and waits, so a chain that reports depth
    # n had n fibers alive at once, each with its own stack, or it could not
    # have got there. Both bursts, so a second one that quietly built less is
    # caught too.
    if [ "$depth1" != "$fibers" ] || [ "$depth2" != "$fibers" ]; then
        echo "fiber_stacks: $label storm never built its chain — reached" \
             "depth $depth1 then $depth2, expected $fibers both times" >&2
        exit 1
    fi

    # What those parked fibers must have cost, and what the join must give
    # back: one committed page each (see the header). Three quarters of it,
    # not all of it, because the worker keeps BEANS_FIBER_POOL_MAX finished
    # fibers with their stacks, and a shared box may reclaim a page between the
    # marker and the sample. Measured runs sit at ~99%, so the quarter is
    # margin, not slack the gate needs.
    local stacks=$((fibers * page / 1024))
    local floor=$((stacks * 3 / 4))
    local grew1=$((p1_r - base_r))
    local fell1=$((p1_r - j1_r))
    echo "  $label: base=${base_r}K high-water=${p1_r}K after-join=${j1_r}K" \
         "(grew ${grew1}K, fell ${fell1}K, ${fibers} stacks ≥ ${stacks}K)"

    if [ "$grew1" -lt "$floor" ]; then
        echo "fiber_stacks: $label storm grew ${grew1}K, but $fibers parked" \
             "fibers commit at least one ${page}-byte page each — ${stacks}K," \
             "and this run is under the ${floor}K floor" >&2
        exit 1
    fi
    # After the join the stacks past the pool bound were released. Measured
    # against the stacks, not against the high-water: the high-water carries
    # the baseline and the object pool, so a fraction of it says nothing about
    # whether the stacks came back, and a run that pooled half of them passed
    # the old 70%-of-high-water rule.
    if [ "$fell1" -lt "$floor" ]; then
        echo "fiber_stacks: $label did not release its stacks — resident fell" \
             "${fell1}K from ${p1_r}K, and $fibers stacks are ${stacks}K" >&2
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
echo "ok fiber stacks: the storm builds its whole chain, hands back at least" \
     "the pages those stacks had to commit, and a warm pool keeps the next" \
     "burst fast — on ${page}-byte pages"
