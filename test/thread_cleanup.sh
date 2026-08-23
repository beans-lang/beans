#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-thread-cleanup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for name in thread_deinit thread_cycles thread_join_exit_cycles \
            shared_publication; do
    ./build/beansc run "test/cases/$name.b" >"$tmp/$name.interp"
    ./build/beansc build "test/cases/$name.b" -o "$tmp/$name.native" \
        >"$tmp/$name.build" 2>&1
    "$tmp/$name.native" >"$tmp/$name.native.out"
    diff -u "test/cases/$name.out" "$tmp/$name.interp"
    diff -u "test/cases/$name.out" "$tmp/$name.native.out"
done

# A join is a full worker teardown barrier. Both a sync worker and an async
# worker leave cycle roots, then main returns immediately after the second
# join. The exit sweep must see zero live workers and reclaim every allocation.
./build/beansc build --emit ir test/cases/thread_join_exit_cycles.b \
    >"$tmp/join-exit.ir"
clang -O1 -pthread -DBEANS_ARC_STATS -Wno-override-module \
    build/thread_join_exit_cycles.ll \
    build/thread_join_exit_cycles_ffi.c build/beans_rt.c -lm \
    -o "$tmp/thread-join-exit"
BEANS_NO_POOL=1 "$tmp/thread-join-exit" \
    >"$tmp/thread-join-exit.out" 2>"$tmp/thread-join-exit.stats"
stats=$(tail -1 "$tmp/thread-join-exit.stats")
allocations=$(sed -n \
    's/.*allocations=\([0-9][0-9]*\).*/\1/p' <<<"$stats")
frees=$(sed -n \
    's/.*frees=\([0-9][0-9]*\).*/\1/p' <<<"$stats")
cycle_objects=$(sed -n \
    's/.*cycle_objects=\([0-9][0-9]*\).*/\1/p' <<<"$stats")
if [[ -z "$allocations" || "$allocations" != "$frees" ||
      -z "$cycle_objects" || "$cycle_objects" -lt 4000 ]]; then
    echo "join returned before complete worker cleanup: $stats" >&2
    exit 1
fi

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
clang -O1 -pthread -DBEANS_ARC_STATS -Wno-override-module \
    build/thread_live_cycles.ll build/thread_live_cycles_ffi.c \
    build/beans_rt.c -lm \
    -o "$tmp/thread-live-cycles"
"$tmp/thread-live-cycles" >"$tmp/thread-live-cycles.out" \
    2>"$tmp/thread-live-cycles.stats"
grep -q '^collected while live true maker 1$' \
    "$tmp/thread-live-cycles.out"
grep -q '^blocker 2$' "$tmp/thread-live-cycles.out"
cycle_objects=$(sed -n \
    's/.*cycle_objects=\([0-9][0-9]*\).*/\1/p' \
    "$tmp/thread-live-cycles.stats")
if [[ -z "$cycle_objects" || "$cycle_objects" -lt 9216 ]]; then
    echo "expected 9216 collected cycle objects, got ${cycle_objects:-none}" >&2
    cat "$tmp/thread-live-cycles.stats" >&2
    exit 1
fi

echo "ok worker-thread destructors and owner-local cycle collection"
