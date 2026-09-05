#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-thread-cleanup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for name in thread_deinit thread_cycles shared_publication; do
    ./build/beansc run "test/cases/$name.b" >"$tmp/$name.interp"
    ./build/beansc build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
done

# Build this probe directly with ARC counters. It reads the counter before the
# long-lived worker exits, proving real cycles (not only dead husks) were
# reclaimed without global thread quiescence.
./build/beansc build --emit ir test/cases/thread_live_cycles.b \
    >"$tmp/live-cycles.ir"
# A shared owner must publish new reference fields before storing them. This
# is what keeps owner-local trial deletion away from later worker handoffs.
grep -q 'call void @beans_cc_write(ptr' build/thread_live_cycles.ll
# Publication points with no heap owner of their own need their own barrier:
# a static slot is reachable from every thread, and Shared marks its payload
# before the first spawn, so writes into that graph must carry the mark too.
./build/beansc build --emit ir test/cases/shared_publication.b \
    >"$tmp/shared-publication.ir"
grep -q 'call void @beans_cc_write_static(ptr' build/shared_publication.ll
grep -q 'call void @beans_cc_write(ptr' build/shared_publication.ll
# A place *inside* a static is the same publication point, one hop down. The
# record store there has no owner object to mark, so it takes the static form
# too — and that is the half nothing else can see: the printed answers and the
# arc markers are identical whether the barrier is emitted or dropped, so a
# store that silently lost it would leave the collector an untracked edge and
# every gate would stay green.
./build/beansc build --emit ir test/cases/parity/static_place.b \
    >"$tmp/static-place.ir"
grep -q 'call void @beans_cc_write_static(ptr' build/static_place.ll
clang -O1 -pthread -DBEANS_ARC_STATS -Wno-override-module \
    build/thread_live_cycles.ll build/thread_live_cycles_ffi.c \
    build/beans_rt.c -lm \
    -o "$tmp/thread-live-cycles"
"$tmp/thread-live-cycles" >"$tmp/thread-live-cycles.out" \
    2>"$tmp/thread-live-cycles.stats"
grep -q '^collected while live true maker 1$' \
    "$tmp/thread-live-cycles.out"
grep -q '^blocker 2$' "$tmp/thread-live-cycles.out"
# The numbers below come from the ARC report an atexit handler writes, and the
# collector's own atexit handler runs before it: `cc_at_exit` drains the entry
# thread's owner-local buffer and then forces up to eight global passes, which
# it is allowed to do because both workers are joined before main returns, so
# cc_threads is zero. Measured with an instrumented copy of the program: it
# reads 7680 collected objects itself, both at the `during` read below and
# again after joining the blocker, and this report says 9216 -- the last 1536
# are reclaimed by that forced sweep. So how far along the collector is *while
# the program runs* is scheduling-dependent (that is the `collected while live`
# claim above, and it is a bound on purpose), but this report's number is not.
# It is read at quiescence, after the collector has been made to finish.
#
# That is why this is an equality and not a bound. The program builds
# 2048 two-node cycles on the maker thread, 2048 more on the entry thread and
# 256 four-object Mutex cycles: 2 * (2048 + 2048) + 4 * 256 = 9216 objects,
# every one of them unreachable before main returns and none of them
# reclaimable by reference counting alone, because each is in a real cycle.
# The decomposition is measured, not assumed: dropping the Mutex loop gives
# exactly 8192 and keeping only the Mutex loop gives exactly 1024.
#
# This was `-lt 9216` and CI saw 9213 once (#64) with frees two short of
# allocations on the same run. That is not the collector being behind -- it has
# been forced to quiescence by the time these numbers are written. It is three
# objects one sweep did not reclaim, two of which were never freed at all.
# Widening the bound would have buried both halves; the two checks below name
# which half went wrong.
stat_field() {
    sed -n "s/.*$1=\([0-9][0-9]*\).*/\1/p" "$tmp/thread-live-cycles.stats"
}
cycle_objects=$(stat_field cycle_objects)
allocations=$(stat_field allocations)
frees=$(stat_field frees)
if [[ -z "$cycle_objects" || -z "$allocations" || -z "$frees" ]]; then
    echo "the ARC stats line no longer carries allocations, frees and" \
         "cycle_objects; this gate read nothing rather than checking it" >&2
    cat "$tmp/thread-live-cycles.stats" >&2
    exit 1
fi
if [[ "$cycle_objects" -ne 9216 ]]; then
    echo "the cycle collector reclaimed $cycle_objects objects, not the 9216" \
         "this program builds. Both workers are joined and the exit sweep is" \
         "forced before this number is written, so the difference is the" \
         "collector, not the machine." >&2
    cat "$tmp/thread-live-cycles.stats" >&2
    exit 1
fi
if [[ "$allocations" -ne "$frees" ]]; then
    echo "$((allocations - frees)) object(s) were allocated and never freed" \
         "($allocations allocated, $frees freed)" >&2
    cat "$tmp/thread-live-cycles.stats" >&2
    exit 1
fi

echo "ok worker-thread destructors and owner-local cycle collection"
