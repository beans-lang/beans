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
# The native backend is the definitive test — a program's Bytes and its
# List<int> are both real runtime backings there. In the tree interpreter a
# program's Bytes is still a real runtime Bytes (so its drop is asserted too),
# but a program's List<int> is 131072 boxed interpreter values, not one
# backing, so its resident set is interpreter object churn and is only run, not
# asserted.

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
    for m in baseline allocated-bytes freed-bytes allocated-lists freed-lists; do
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
read -r n_base n_ab n_fb n_al n_fl < <(drive "$tmp/rss-native")
want_drop "native bytes" "$n_base" "$n_ab" "$n_fb"
want_drop "native lists" "$n_base" "$n_al" "$n_fl"

echo "checking freed large allocations leave RSS (interpreter, Bytes)"
read -r i_base i_ab i_fb i_al i_fl < <(drive "$BEANSC" run "$prog")
want_drop "interp bytes" "$i_base" "$i_ab" "$i_fb"
# The interpreter's List<int> phase is run (it must not crash) but not asserted:
# there a program's ints are boxed interpreter objects, not one runtime backing,
# so its resident set is object churn, not the mmap the fix returns.
echo "  interp lists ran (base=${i_base}K allocated=${i_al}K freed=${i_fl}K); not asserted — boxed values, not a backing"

echo "ok rss: 32 MiB of freed Bytes and List backings returned to the OS"
