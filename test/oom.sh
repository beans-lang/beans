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
# sanitizer-gate: leaks are off here on purpose (detect_leaks=0) -- the whole
# point of the sweep is to stop the program mid-allocation, and every injected
# failure ends in a panic that never gets to unwind. A LeakSanitizer report
# would fire on every one of the 251 points and say nothing about the defect
# this gate exists to catch. `sweep` still classifies every exit status, so an
# AddressSanitizer or UndefinedBehaviorSanitizer abort lands in the crash
# bucket and is printed.
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

# --- a refused large-block mapping ------------------------------------------
#
# The sweep above cannot reach the large-block allocator: a block at or past the
# map threshold is served by mmap, which BEANS_OOM_AFTER's countdown does not
# sit in front of. That path has its own refusal rule and it is not the same for
# both of its allocators, so it needs its own probe.
#
# A Bytes or List backing carries no header. Its free is handed the byte size
# the allocation was given and decides munmap-or-free from that size alone, so a
# block at or past the threshold has to BE a mapping. Falling back to the heap
# when the mapping fails would put a malloc'd pointer into munmap — and a large
# malloc is page-aligned often enough (macOS serves them from vm_allocate) that
# the unmap would succeed and quietly take live heap away rather than fail with
# EINVAL. So a refused mapping is a refused allocation, and every call site turns
# that into the runtime's documented "out of memory" panic.
#
# A non-pooled beans_alloc object — a large string — records in its 16-byte
# prefix whether it was mapped, so its free can tell either way. That one falls
# back to the heap and keeps working, which is why the two are written
# differently instead of sharing one shape.
#
# BEANS_RT_BIG_NOMMAP makes every large mapping fail. Like BEANS_OOM_AFTER it
# lives only under -DBEANS_RT_ALLOC_FAILTEST, so no shipped binary can have its
# allocator changed by an inherited environment variable.
echo "emitting the large-block probe's IR"
./build/beansc build test/cases/oom_big_map.b -o "$tmp/bigprobe" >"$tmp/bigbuild"
llbig=build/oom_big_map.ll
test -f "$llbig" || { echo "expected $llbig from the build step" >&2; exit 1; }

echo "compiling the large-block probe with mapping-failure injection"
clang -O1 -g -pthread -Wno-override-module "$llbig" runtime/beans_rt.c -lm \
    -DBEANS_RT_ALLOC_FAILTEST -o "$tmp/bigmap"

echo "checking every phase runs when mapping works"
"$tmp/bigmap" >"$tmp/bigmap.out"
diff -u - "$tmp/bigmap.out" <<'EXPECTED'
small 1024
string 262144
bytes 262144
EXPECTED

echo "checking a refused mapping refuses the backing and falls back for the object"
set +e
nomap=$(BEANS_RT_BIG_NOMMAP=1 "$tmp/bigmap" 2>&1); nomap_code=$?
set -e
if [ "$nomap_code" -ne 3 ]; then
    echo "a refused large mapping exited $nomap_code, not the documented OOM panic (3):" >&2
    printf '%s\n' "$nomap" | head -6 >&2
    exit 1
fi
printf '%s' "$nomap" | grep -q "out of memory" || {
    echo "a refused large mapping did not panic with 'out of memory':" >&2
    printf '%s\n' "$nomap" | head -6 >&2
    exit 1
}
printf '%s' "$nomap" | grep -q '^small 1024$' || {
    echo "a sub-threshold buffer must still allocate when mapping is refused" >&2
    exit 1
}
printf '%s' "$nomap" | grep -q '^string 262144$' || {
    echo "a large string must fall back to the heap: its prefix records the origin" >&2
    printf '%s\n' "$nomap" | head -6 >&2
    exit 1
}
if printf '%s' "$nomap" | grep -q '^bytes '; then
    echo "a large Bytes backing was served from the heap after its mapping failed;" >&2
    echo "its free would hand that pointer to munmap" >&2
    exit 1
fi

echo "ok every container-grow allocation refuses OOM with the documented panic, sanitizer-clean"
