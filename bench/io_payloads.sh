#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
binary=${BEANS_PAYLOAD_BINARY:-build/bench_io_payloads}
if [[ -z "${BEANS_PAYLOAD_BINARY:-}" ]]; then
    ./build/beansc build --release bench/io_payloads.b -o "$binary"
fi
runs=${BEANS_PAYLOAD_RUNS:-5}

for mode in process datagram; do
    if [[ "$mode" == process ]]; then
        size=${BEANS_PROCESS_SIZE:-16777216}
        rounds=${BEANS_PROCESS_ROUNDS:-2}
    else
        size=${BEANS_DATAGRAM_SIZE:-8192}
        rounds=${BEANS_DATAGRAM_ROUNDS:-10000}
    fi
    "$binary" "$mode" "$size" "$rounds" >/dev/null
    for run in $(seq 1 "$runs"); do
        "$binary" "$mode" "$size" "$rounds" >"build/bench_io_payloads.$mode.$run"
    done
    awk -v mode="$mode" -v runs="$runs" -v dir="build" '
        {
            file = dir "/bench_io_payloads." mode "." NR
            getline row < file
            close(file)
            split(row, fields, " ")
            samples[NR] = fields[5] + 0
            check[NR] = fields[6]
        }
        END {
            for (i = 2; i <= runs; i++) {
                value = samples[i]
                j = i - 1
                while (j > 0 && samples[j] > value) {
                    samples[j + 1] = samples[j]
                    j--
                }
                samples[j + 1] = value
            }
            printf("payload %s median %.3f ms checksum %s\n", mode,
                   samples[int((runs + 1) / 2)] / 1000000.0, check[1])
        }
    ' < <(seq 1 "$runs")
done
