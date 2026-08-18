#!/usr/bin/env bash
set -euo pipefail

# Reproducible focused check for fs.read, fs.write, and fs.copy. Timing is a
# median after one warm-up. The final fields are stable correctness checks.

cd "$(dirname "$0")/.."
binary=${BEANS_IO_BINARY:-build/bench_io_boundaries}
if [[ -z "${BEANS_IO_BINARY:-}" ]]; then
    ./build/beansc build --release bench/io_boundaries.b -o "$binary"
fi

size=${BEANS_IO_SIZE:-67108864}
rounds=${BEANS_IO_ROUNDS:-5}
runs=${BEANS_IO_RUNS:-5}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/beans-io-bench.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

run_once() {
    local mode=$1
    if [[ "$mode" == read || "$mode" == copy ]]; then
        dd if=/dev/zero of="$scratch/beans_io_boundary_source" bs=1 count=0 \
            seek="$size" 2>/dev/null
        "$binary" "$mode" "$scratch" "$size" "$rounds" prepared
    else
        "$binary" "$mode" "$scratch" "$size" "$rounds"
    fi
}

for mode in read write copy; do
    run_once "$mode" >/dev/null
    for run in $(seq 1 "$runs"); do
        run_once "$mode" >"build/bench_io_boundaries.$mode.$run"
    done
    awk -v mode="$mode" -v runs="$runs" -v dir="build" '
        {
            file = dir "/bench_io_boundaries." mode "." NR
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
            printf("io %s median %.3f ms checksum %s\n", mode,
                   samples[int((runs + 1) / 2)] / 1000000.0, check[1])
        }
    ' < <(seq 1 "$runs")
done
