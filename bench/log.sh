#!/usr/bin/env bash
set -euo pipefail

# Reproducible focused std.log benchmark. Numbers are medians after one warmup.
# Override sizes with BEANS_LOG_DISABLED, BEANS_LOG_EXPORT, and BEANS_LOG_IO.

cd "$(dirname "$0")/.."
binary=${BEANS_LOG_BINARY:-build/bench_log}
if [[ -z "${BEANS_LOG_BINARY:-}" ]]; then
    ./build/beansc build --release --lto --cpu native \
        bench/log.b -o "$binary" >/dev/null
fi

disabled=${BEANS_LOG_DISABLED:-1000000}
exported=${BEANS_LOG_EXPORT:-250000}
io_count=${BEANS_LOG_IO:-100000}
runs=${BEANS_LOG_RUNS:-5}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/beans-log-bench.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

for row in "disabled:$disabled" "export:$exported" \
           "file:$io_count" "json:$io_count"; do
    mode=${row%%:*}
    count=${row#*:}
    "$binary" "$mode" "$scratch/$mode.log" "$count" >/dev/null
    for sample in $(seq 1 "$runs"); do
        "$binary" "$mode" "$scratch/$mode.log" "$count" \
            >"$scratch/$mode.$sample"
    done
    awk -v mode="$mode" -v runs="$runs" -v dir="$scratch" '
        {
            file = dir "/" mode "." NR
            getline ignored < file
            getline row < file
            close(file)
            split(row, fields, " ")
            values[NR] = fields[4] + 0
            count = fields[3]
            dropped = fields[5]
        }
        END {
            for (i = 2; i <= runs; i++) {
                value = values[i]
                j = i - 1
                while (j > 0 && values[j] > value) {
                    values[j + 1] = values[j]
                    j--
                }
                values[j + 1] = value
            }
            median = values[int((runs + 1) / 2)]
            printf("log %-8s median %.1f ns/call (%s calls, dropped %s)\n",
                   mode, median / count, count, dropped)
        }
    ' < <(seq 1 "$runs")
done
