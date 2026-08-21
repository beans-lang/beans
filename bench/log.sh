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
           "export_live:${BEANS_LOG_EXPORT_LIVE:-100000}" \
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
            getline queued_row < file
            getline row < file
            close(file)
            split(queued_row, queued_fields, "=")
            queued[NR] = queued_fields[2] + 0
            split(row, fields, " ")
            values[NR] = fields[4] + 0
            count = fields[3]
            producer_dropped[NR] = fields[5]
            sink_dropped[NR] = fields[6]
        }
        END {
            for (i = 2; i <= runs; i++) {
                value = values[i]
                q = queued[i]
                pd = producer_dropped[i]
                sd = sink_dropped[i]
                j = i - 1
                while (j > 0 && values[j] > value) {
                    values[j + 1] = values[j]
                    queued[j + 1] = queued[j]
                    producer_dropped[j + 1] = producer_dropped[j]
                    sink_dropped[j + 1] = sink_dropped[j]
                    j--
                }
                values[j + 1] = value
                queued[j + 1] = q
                producer_dropped[j + 1] = pd
                sink_dropped[j + 1] = sd
            }
            middle = int((runs + 1) / 2)
            if (queued[middle] > 0) {
                printf("log %-11s median %.1f ns/attempt, %.1f ns/queued (%s queued, producer dropped %s, sink dropped %s)\n",
                       mode, values[middle] / count,
                       values[middle] / queued[middle], queued[middle],
                       producer_dropped[middle], sink_dropped[middle])
            } else {
                printf("log %-11s median %.1f ns/attempt (%s queued, producer dropped %s, sink dropped %s)\n",
                       mode, values[middle] / count, queued[middle],
                       producer_dropped[middle], sink_dropped[middle])
            }
        }
    ' < <(seq 1 "$runs")
done
