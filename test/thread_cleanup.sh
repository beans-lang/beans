#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-thread-cleanup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# thread_claim: issue #124's thread half. join() MOVES the result out of the
# handle -- beans_thread_join zeroes t->result -- so the value dies with the
# binding that took it. The interpreter used to cache a copy on the handle, so
# the value outlived that binding and died only when the handle did. Each case
# puts a loud local between the handle and the binding that joins it, at one,
# two and three threads, so the LIFO teardown tells the two moments apart.
for name in thread_deinit thread_cycles shared_publication thread_claim; do
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
cycle_objects=$(sed -n \
    's/.*cycle_objects=\([0-9][0-9]*\).*/\1/p' \
    "$tmp/thread-live-cycles.stats")
if [[ -z "$cycle_objects" || "$cycle_objects" -lt 9216 ]]; then
    echo "expected 9216 collected cycle objects, got ${cycle_objects:-none}" >&2
    cat "$tmp/thread-live-cycles.stats" >&2
    exit 1
fi

# A thread is joined once, on both engines. beans_thread_join panics on the
# second join; the interpreter used to answer the cached copy it kept on the
# handle, so a double join quietly succeeded under `beansc run` and killed the
# process the first time the same program was built (#124). The cleared handle
# is the joined marker now, so both engines report and exit 3.
cat >"$tmp/twice.b" <<'BEANS'
import std.io
import std.thread

fn main() {
    let worker: Thread<int> = thread.spawn(fn() -> int { return 7 })
    io.println("first {worker.join()}")
    io.println("second {worker.join()}")
}
BEANS
expect_second_join_dies() { # <command...>
    set +e
    "$@" >"$tmp/twice.out" 2>"$tmp/twice.err"
    local status=$?
    set -e
    if [ "$status" -ne 3 ]; then
        echo "a second thread join should exit 3, got $status" >&2
        cat "$tmp/twice.out" "$tmp/twice.err" >&2
        exit 1
    fi
    grep -q '^first 7$' "$tmp/twice.out"
    grep -q 'thread already joined' "$tmp/twice.err"
    if grep -q '^second ' "$tmp/twice.out"; then
        echo "a second thread join answered a value" >&2
        cat "$tmp/twice.out" >&2
        exit 1
    fi
}
expect_second_join_dies ./build/beansc run "$tmp/twice.b"
./build/beansc build "$tmp/twice.b" -o "$tmp/twice" >/dev/null 2>&1
expect_second_join_dies "$tmp/twice"

echo "ok worker-thread destructors and owner-local cycle collection"
