#!/usr/bin/env bash
set -euo pipefail

# A freed large allocation must leave the resident set. The runtime maps a
# Bytes or List backing past its threshold instead of malloc'ing it, so freeing
# one unmaps its pages and `ps` stops counting them — where a plain free on
# macOS only marks the pages reclaimable and leaves them resident until the
# machine is under pressure.
#
# test/cases/rss_release.b holds 32 live one-mebibyte backings, all touched so
# their pages are real, prints a marker on stderr and then blocks on stdin at
# each phase. This driver samples RSS at each marker and then lets the program
# advance, so a sample is never taken mid-phase. The headline is the drop from
# the "allocated" sample to the "freed" one: with the fix it is the whole
# 32 MiB; without it, near zero on macOS.
#
# Three shapes: a Bytes backing and a List<int> backing (the rt_big path) and
# a large string (a non-pooled beans_alloc object — the rt_obj path). The
# native backend is the definitive test: a program's Bytes, its List<int> and
# its string are each one real runtime allocation there. In the tree
# interpreter a program's Bytes is still a real runtime Bytes (so its drop is
# asserted too), but a program's List<int> is 131072 boxed interpreter values
# and its string is the interpreter's own churned storage — not one runtime
# allocation — so those two are only run, not asserted.

cd "$(dirname "$0")/.."
BEANSC=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-rss.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if ! command -v ps >/dev/null 2>&1; then
    echo "rss_release: ps not found — cannot sample resident memory" >&2
    exit 1
fi

prog=test/cases/rss_release.b
"$BEANSC" build "$prog" -o "$tmp/rss-native" >"$tmp/build.log" 2>&1

# drive <label> <cmd...> : run one backend through its five phases, writing
# "base ab fb al fl" (RSS in KiB) to stdout.
drive() {
    local work
    work=$(mktemp -d "$tmp/run.XXXXXX")
    mkfifo "$work/in"
    : >"$work/err"
    "$@" <"$work/in" 2>"$work/err" >/dev/null &
    local pid=$!
    exec 7>"$work/in"   # hold stdin open so read_line blocks rather than seeing EOF

    local out="" m sample tries
    for m in baseline allocated-bytes freed-bytes allocated-lists freed-lists \
             allocated-strings freed-strings allocated-records freed-records; do
        tries=0
        until grep -q "phase $m" "$work/err" 2>/dev/null; do
            if ! kill -0 "$pid" 2>/dev/null; then
                exec 7>&-
                echo "rss_release: process exited before marker '$m'" >&2
                return 1
            fi
            tries=$((tries + 1))
            if [ "$tries" -gt 6000 ]; then
                exec 7>&-; kill "$pid" 2>/dev/null || true
                echo "rss_release: timed out waiting for marker '$m'" >&2
                return 1
            fi
            sleep 0.01
        done
        sample=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$sample" ] || sample=0
        out="$out $sample"
        echo >&7   # advance past this marker
    done
    exec 7>&-
    wait "$pid" 2>/dev/null || true
    echo "${out# }"
}

# want_drop <what> <base> <allocated> <freed> : the allocation must be real
# (>= 24 MiB over baseline) and freeing must return most of it (the freed
# sample within 8 MiB of baseline).
want_drop() {
    local what=$1 base=$2 alloc=$3 freed=$4
    local grew=$((alloc - base)) back=$((freed - base))
    echo "  $what: base=${base}K allocated=${alloc}K freed=${freed}K (grew ${grew}K, freed-minus-base ${back}K)"
    if [ "$grew" -lt 24000 ]; then
        echo "rss_release: $what never grew — the backings were not resident (grew ${grew}K)" >&2
        exit 1
    fi
    if [ "$back" -gt 8000 ]; then
        echo "rss_release: $what did not return to the OS — freed set stayed ${back}K over baseline" >&2
        exit 1
    fi
}

echo "checking freed large allocations leave RSS (native)"
read -r n_base n_ab n_fb n_al n_fl n_as n_fs n_ar n_fr < <(drive "$tmp/rss-native")
want_drop "native bytes" "$n_base" "$n_ab" "$n_fb"
want_drop "native lists" "$n_base" "$n_al" "$n_fl"
want_drop "native strings" "$n_base" "$n_as" "$n_fs"
# The records-sized blocks are 262144 bytes, the backing a 247 KB response body
# actually lands in once a Bytes has doubled its way there, and the first
# doubling step at or above the map threshold. It is the tripwire directly above
# the threshold: raise the threshold and a real response body stops returning
# its pages, and this line fails.
want_drop "native records (256 KB)" "$n_base" "$n_ar" "$n_fr"

echo "checking freed large allocations leave RSS (interpreter, Bytes)"
read -r i_base i_ab i_fb i_al i_fl i_as i_fs i_ar i_fr < <(drive "$BEANSC" run "$prog")
want_drop "interp bytes" "$i_base" "$i_ab" "$i_fb"
# The interpreter's List<int> and string phases are run (they must not crash)
# but not asserted: there a program's ints and its strings are the interpreter's
# own churned objects, not a single runtime allocation, so their resident set is
# interpreter churn, not the mmap the fix returns. The native backend, which
# holds each as one runtime object, is where the rt_obj map path is asserted.
echo "  interp lists ran (base=${i_base}K allocated=${i_al}K freed=${i_fl}K); not asserted — boxed values, not a backing"
echo "  interp strings ran (base=${i_base}K allocated=${i_as}K freed=${i_fs}K); not asserted — interpreter string churn, not one object"
echo "  interp records ran (base=${i_base}K allocated=${i_ar}K freed=${i_fr}K); not asserted — the interpreter's per-iteration churn dominates 160 blocks"

# --- contents across the threshold ------------------------------------------
#
# The samples above count pages; they say nothing about what is in them. A grow
# that crosses the threshold is not a realloc: it is a fresh block, a memcpy of
# the overlap and a release of the old one, and so is a grow of a block that is
# already mapped. test/cases/big_realloc.b drives every call site that can do
# that — push, reserve and resize on a Bytes, push, reserve and insert on a
# List — starting once below the threshold so the grow crosses it and once
# above so it is map-to-map, and prints a crc32 or a positional digest of the
# result. Both backends must print the same lines and both must match the
# golden, so a copy that started at the wrong offset, stopped short, or landed
# in the wrong block shows up as a changed number rather than as nothing.
echo "checking a grown backing keeps its bytes across the map threshold"
# Every size in big_realloc.b is chosen to land on a particular side of the map
# threshold, and a Bytes or List capacity only ever doubles, so moving the
# threshold silently moves the cases to the wrong side: they stop crossing it
# and go on passing, having tested nothing. The same is true of the records
# phase above, whose 262144-byte blocks are the first doubling step at or over
# the threshold. So the number itself is pinned here — not as a test of the
# value, but so that changing it fails loudly and sends whoever changed it back
# to retune the sizes in both files.
want_threshold='#define RT_BIG_MMAP_MIN (256u * 1024u)'
if ! grep -qF "$want_threshold" runtime/beans_rt.c; then
    echo "rss_release: the large-block map threshold is no longer 256 KB." >&2
    echo "The sizes in test/cases/big_realloc.b and the records phase of" >&2
    echo "test/cases/rss_release.b bracket that number and must be retuned" >&2
    echo "around the new one, or they will keep passing without crossing it." >&2
    grep -n 'define RT_BIG_MMAP_MIN' runtime/beans_rt.c >&2
    exit 1
fi
realloc_prog=test/cases/big_realloc.b
"$BEANSC" build "$realloc_prog" -o "$tmp/big-realloc" >"$tmp/realloc-build.log" 2>&1
"$tmp/big-realloc" >"$tmp/realloc-native.out"
"$BEANSC" run "$realloc_prog" >"$tmp/realloc-interp.out"
diff -u "$tmp/realloc-interp.out" "$tmp/realloc-native.out"
diff -u - "$tmp/realloc-native.out" <<'EXPECTED'
bytes-push len 300000 crc 2471502865
bytes-reserve-cross len 200000 crc 842714851 unchanged true
bytes-reserve-mapped len 300000 crc 1574020299 unchanged true
bytes-resize len 300000 kept true tail-crc 1558206587
list-push len 70000 digest 176966798 first 1 last 209998
list-reserve len 16384 unchanged true digest 203612390
list-insert len 16385 head 424242 second 5 last 180218 digest 809618687
EXPECTED

echo "ok rss: 32 MiB of freed Bytes and List backings returned to the OS, and a grow across the threshold keeps every byte"
