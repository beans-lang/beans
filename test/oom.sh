#!/usr/bin/env bash
# #108: every runtime allocation on a container-mutation path must refuse an
# out-of-memory failure with the runtime's documented "out of memory" panic, not
# a NULL dereference. map_insert_miss stored the key and value into a NULL buffer
# when its grow's realloc failed; the same omission sat in map_insert_miss_typed
# and beans_map_reserve (the deadbits realloc), in beans_map_new's initial data,
# in map_reindex_to's index, and in the untyped List insert and Bytes append.
#
# The runtime carries a test-only allocation-failure injection hook, compiled in
# ONLY under -DBEANS_RT_ALLOC_FAILTEST and never in a release build:
# BEANS_OOM_AFTER=N lets N allocations succeed and makes the next return NULL.
# This gate sweeps N across every allocation test/cases/oom_alloc_fail.b makes
# and holds each failure to a clean panic. A crash (SIGSEGV) at any point is the
# defect. A second pass under ASan/UBSan proves the release-before-panic paths —
# a refused typed/managed-key grow releases the value and key it was handed —
# touch no freed memory.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-oom.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export BEANS_RUNTIME=runtime/beans_rt.c BEANS_STDLIB=stdlib/std \
       BEANS_ENCODING=runtime/encoding BEANS_NET=runtime/net BEANS_LOG=runtime/log
# An out-of-memory panic legitimately leaves memory held, so the sanitizer pass
# is checking use-after-free and overflow, not leaks.
export ASAN_OPTIONS=detect_leaks=0

echo "emitting the OOM probe's IR"
./build/beansc build test/cases/oom_alloc_fail.b -o "$tmp/probe" >"$tmp/build"
ll=build/oom_alloc_fail.ll
test -f "$ll" || { echo "expected $ll from the build step" >&2; exit 1; }

# With the real allocator the probe just runs and pins its answer.
"$tmp/probe" >"$tmp/probe.out"
grep -q '^oom-probe complete' "$tmp/probe.out"

# Sweep BEANS_OOM_AFTER 0..max and classify every outcome. Every failure must be
# exit 3 carrying "out of memory"; anything else (a SIGSEGV is exit 139) is the
# NULL-dereference defect. A full-completion run must appear, which proves the
# sweep bound is past the last allocation — otherwise a later unchecked site
# could hide beyond the bound.
sweep() {
    local bin="$1" maxn="$2" label="$3"
    local ok=0 oom=0 crash=0 firstok=-1 n out code
    for n in $(seq 0 "$maxn"); do
        set +e
        out=$(BEANS_NO_POOL=1 BEANS_OOM_AFTER="$n" "$bin" 2>&1); code=$?
        set -e
        if [ "$code" -eq 0 ]; then
            ok=$((ok + 1)); [ "$firstok" -lt 0 ] && firstok=$n
        elif [ "$code" -eq 3 ] && printf '%s' "$out" | grep -q "out of memory"; then
            oom=$((oom + 1))
        else
            crash=$((crash + 1))
            echo "$label: OOM at allocation #$n did not panic cleanly (exit $code):" >&2
            printf '%s\n' "$out" | head -4 >&2
        fi
    done
    if [ "$crash" -ne 0 ]; then
        echo "$label: $crash injection point(s) crashed instead of panicking" >&2
        exit 1
    fi
    if [ "$oom" -eq 0 ]; then
        echo "$label: no injection point reached an allocation — probe not exercising the paths" >&2
        exit 1
    fi
    if [ "$firstok" -lt 0 ]; then
        echo "$label: probe allocates more than the swept $((maxn + 1)) points — raise the bound" >&2
        exit 1
    fi
    echo "$label: swept $((maxn + 1)) points, $oom clean out-of-memory panics, full run first at N=$firstok, 0 crashes"
}

echo "compiling the probe with allocation-failure injection"
clang -O1 -g -pthread -Wno-override-module "$ll" runtime/beans_rt.c -lm \
    -DBEANS_RT_ALLOC_FAILTEST -o "$tmp/oom"
echo "sweeping every allocation for a clean out-of-memory panic"
sweep "$tmp/oom" 250 "plain"

echo "compiling the probe under ASan and UBSan with the same injection"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module "$ll" runtime/beans_rt.c -lm \
    -DBEANS_RT_ALLOC_FAILTEST -o "$tmp/oom.asan"
echo "sweeping again under the sanitizers"
sweep "$tmp/oom.asan" 250 "asan"

echo "ok every container-grow allocation refuses OOM with the documented panic, sanitizer-clean"
