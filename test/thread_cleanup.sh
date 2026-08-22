#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-thread-cleanup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for name in thread_deinit thread_cycles; do
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
clang -O1 -pthread -DBEANS_ARC_STATS -Wno-override-module \
    build/thread_live_cycles.ll build/thread_live_cycles_ffi.c \
    build/beans_rt.c -lm \
    -o "$tmp/thread-live-cycles"
"$tmp/thread-live-cycles" >"$tmp/thread-live-cycles.out" \
    2>"$tmp/thread-live-cycles.stats"
grep -q '^collected while live true maker 1$' \
    "$tmp/thread-live-cycles.out"
grep -q '^blocker 2$' "$tmp/thread-live-cycles.out"
grep -Eq 'cycle_objects=[4-9][0-9]{3,}|cycle_objects=[1-9][0-9]{4,}' \
    "$tmp/thread-live-cycles.stats"

echo "ok worker-thread destructors and owner-local cycle collection"
