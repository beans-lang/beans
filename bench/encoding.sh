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

# Timing on a laptop is noisy, so the reported figure is a median of repeated
# runs after a discarded warm-up rather than a single sample. BEANS_BENCH_RUNS
# sets how many measured runs (default 5); the raw runs stay in build/ for
# inspection.
runs=${BEANS_BENCH_RUNS:-5}
echo "warm-up run (discarded)"
./build/bench_encoding >/dev/null 2>&1 || true
for index in $(seq 1 "$runs"); do
    ./build/bench_encoding >"build/bench_encoding.run$index" 2>&1
done
echo "median of $runs runs after warm-up:"
echo ""
# Every run prints the same rows in the same order, so the median is taken
# per line across runs on the numeric field each row reports.
awk -v runs="$runs" -v dir=build '
BEGIN {
    for (r = 1; r <= runs; r++) {
        file = dir "/bench_encoding.run" r
        line = 0
        while ((getline row < file) > 0) {
            line++
            rows[line, r] = row
        }
        close(file)
        if (line > total) total = line
    }
    for (l = 1; l <= total; l++) {
        # find the MiB/s field, if this row has one
        n = split(rows[l, 1], parts, " ")
        field = 0
        for (i = 1; i <= n; i++) if (parts[i] == "MiB/s") field = i - 1
        if (field == 0) { print rows[l, 1]; continue }
        delete samples
        for (r = 1; r <= runs; r++) {
            split(rows[l, r], p, " ")
            samples[r] = p[field] + 0
        }
        # insertion sort, then the middle sample
        for (a = 2; a <= runs; a++) {
            v = samples[a]
            b = a - 1
            while (b > 0 && samples[b] > v) { samples[b + 1] = samples[b]; b-- }
            samples[b + 1] = v
        }
        median = samples[int((runs + 1) / 2)]
        split(rows[l, 1], p, " ")
        out = ""
        for (i = 1; i <= n; i++) {
            out = out (i == field ? sprintf("%.2f", median) : p[i]) " "
        }
        print out
    }
}
' </dev/null

# Peak RSS around one more run. Both time(1) spellings print it; neither is
# available everywhere, so the run happens either way and the memory line is
# reported when it can be.
echo ""
peak=""
if /usr/bin/time -l true >/dev/null 2>&1; then
    /usr/bin/time -l ./build/bench_encoding >/dev/null 2>"$PWD/build/bench_encoding.time"
    peak=$(awk '/maximum resident set size/ {print $1}' \
        "$PWD/build/bench_encoding.time")
    [[ -n "$peak" ]] && peak="$((peak / 1024)) KiB"
elif /usr/bin/time -v true >/dev/null 2>&1; then
    /usr/bin/time -v ./build/bench_encoding >/dev/null 2>"$PWD/build/bench_encoding.time"
    peak=$(awk -F': ' '/Maximum resident set size/ {print $2}' \
        "$PWD/build/bench_encoding.time")
    [[ -n "$peak" ]] && peak="$peak KiB"
fi

echo ""
if [[ -n "$peak" ]]; then
    echo "peak resident set size (whole run): $peak"
else
    echo "peak resident set size: not measured (no time(1) with an RSS report)"
fi
