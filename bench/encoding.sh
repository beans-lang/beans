#!/usr/bin/env bash
set -euo pipefail

# Reproducible std.encoding benchmark. Run by hand:
#
#   bash bench/encoding.sh
#
# Timing numbers are machine-dependent and are deliberately not a CI gate;
# the checksums in the output are the only stable part. The claim-eligible
# language benchmark stays bench/run.sh — this file exists so encoding
# changes can be measured before and after, on one machine.

cd "$(dirname "$0")/.."

if [[ ! -x build/beansc ]]; then
    echo "build/beansc is missing; run make first" >&2
    exit 1
fi

echo "== host =="
uname -sm
if [[ "$(uname)" == "Darwin" ]]; then
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
elif [[ -r /proc/cpuinfo ]]; then
    grep -m1 "model name" /proc/cpuinfo | sed 's/.*: //' || true
fi
echo ""

./build/beansc build --release bench/encoding.b -o build/bench_encoding

# Peak RSS around the whole run. Both time(1) spellings print it; neither is
# available everywhere, so the run happens either way and the memory line is
# reported when it can be.
peak=""
if /usr/bin/time -l true >/dev/null 2>&1; then
    /usr/bin/time -l ./build/bench_encoding 2>"$PWD/build/bench_encoding.time"
    peak=$(awk '/maximum resident set size/ {print $1}' \
        "$PWD/build/bench_encoding.time")
    [[ -n "$peak" ]] && peak="$((peak / 1024)) KiB"
elif /usr/bin/time -v true >/dev/null 2>&1; then
    /usr/bin/time -v ./build/bench_encoding 2>"$PWD/build/bench_encoding.time"
    peak=$(awk -F': ' '/Maximum resident set size/ {print $2}' \
        "$PWD/build/bench_encoding.time")
    [[ -n "$peak" ]] && peak="$peak KiB"
else
    ./build/bench_encoding
fi

echo ""
if [[ -n "$peak" ]]; then
    echo "peak resident set size (whole run): $peak"
else
    echo "peak resident set size: not measured (no time(1) with an RSS report)"
fi
