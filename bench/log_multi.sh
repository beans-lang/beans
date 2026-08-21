#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
binary=${BEANS_LOG_MULTI_BINARY:-build/bench_log_multi}
if [[ -z "${BEANS_LOG_MULTI_BINARY:-}" ]]; then
    ./build/beansc build --release --lto --cpu native \
        bench/log_multi.b -o "$binary" >/dev/null
fi

runs=${BEANS_LOG_RUNS:-5}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/beans-log-multi.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

for mode in disabled file; do
    count=${BEANS_LOG_MULTI_DISABLED:-1000000}
    if [[ "$mode" == "file" ]]; then
        count=${BEANS_LOG_MULTI_FILE:-200000}
    fi
    for workers in 1 2 4 8; do
        "$binary" "$mode" "$workers" "$count" "$scratch/$mode.log" \
            >/dev/null
        for sample in $(seq 1 "$runs"); do
            "$binary" "$mode" "$workers" "$count" \
                "$scratch/$mode.log" >"$scratch/$mode.$workers.$sample"
        done
        awk -v mode="$mode" -v workers="$workers" -v runs="$runs" \
            -v dir="$scratch" '
            {
                file = dir "/" mode "." workers "." NR
                getline row < file
                close(file)
                split(row, fields, " ")
                elapsed[NR] = fields[5] + 0
                calls = fields[4]
                queued[NR] = fields[6]
                dropped[NR] = fields[7]
            }
            END {
                for (i = 2; i <= runs; i++) {
                    value = elapsed[i]
                    q = queued[i]
                    d = dropped[i]
                    j = i - 1
                    while (j > 0 && elapsed[j] > value) {
                        elapsed[j + 1] = elapsed[j]
                        queued[j + 1] = queued[j]
                        dropped[j + 1] = dropped[j]
                        j--
                    }
                    elapsed[j + 1] = value
                    queued[j + 1] = q
                    dropped[j + 1] = d
                }
                middle = int((runs + 1) / 2)
                if (queued[middle] > 0) {
                    printf("log %-8s %d workers median %.1f ns/attempt, %.1f ns/queued (%s queued, %s dropped)\n",
                           mode, workers, elapsed[middle] / calls,
                           elapsed[middle] / queued[middle],
                           queued[middle], dropped[middle])
                } else {
                    printf("log %-8s %d workers median %.1f ns/attempt (%s queued, %s dropped)\n",
                           mode, workers, elapsed[middle] / calls,
                           queued[middle], dropped[middle])
                }
            }
        ' < <(seq 1 "$runs")
    done
done
