#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

mode=${1:-verify}
case "$mode" in
    verify) rounds=1 ;;
    quick) rounds=3 ;;
    full) rounds=9 ;;
    *) echo "usage: bench/abstractions/run.sh <verify|quick|full>" >&2; exit 2 ;;
esac

out=build/abstractions
mkdir -p "$out"
make -s build/beansc

now() {
    perl -MTime::HiRes=time -e 'printf "%.9f", time'
}

median() {
    LC_ALL=C sort -n "$1" | awk '
        { values[NR] = $1 }
        END {
            if (NR == 0) { print "0"; exit }
            if (NR % 2 == 1) { printf "%.6f", values[(NR + 1) / 2] }
            else { printf "%.6f", (values[NR / 2] + values[NR / 2 + 1]) / 2 }
        }
    '
}

printf 'workload\tvariant\tseconds\tallocations\tretains\treleases\n'

while IFS=$'\t' read -r name variants full_size seed; do
    [[ -z "$name" || "${name:0:1}" == "#" ]] && continue
    source="bench/abstractions/$name.b"
    binary="$out/$name"
    arc_binary="$out/$name-arc"
    ./build/beansc build --release --lto --cpu native \
        "$source" -o "$binary" >/dev/null
    clang -O3 -march=native -pthread -DBEANS_ARC_STATS \
        -Wno-override-module "build/$name.ll" build/beans_rt.c \
        -lm -o "$arc_binary"
    clang -O3 -S -emit-llvm -Wno-override-module \
        "build/$name.ll" -o "$out/$name.opt.ll"

    size=$full_size
    if [[ "$mode" == "verify" ]]; then
        size=10000
    elif [[ "$mode" == "quick" ]]; then
        size=$((full_size / 10))
        if (( size < 100000 )); then size=100000; fi
    fi

    IFS=',' read -r -a choices <<<"$variants"
    expected="$out/$name.expected"
    first=1
    for variant in "${choices[@]}"; do
        actual="$out/$name-$variant.out"
        stats="$out/$name-$variant.arc"
        "$arc_binary" "$variant" "$size" "$seed" \
            >"$actual" 2>"$stats"
        if (( first )); then
            cp "$actual" "$expected"
            first=0
        else
            diff -u "$expected" "$actual"
        fi

        # Keep process startup, dyld and page-cache coldness out of the first
        # measured variant. Every variant gets the same unmeasured warmup.
        "$binary" "$variant" "$size" "$seed" >/dev/null
        samples="$out/$name-$variant.samples"
        : >"$samples"
        for ((round = 0; round < rounds; round += 1)); do
            start=$(now)
            "$binary" "$variant" "$size" "$seed" >/dev/null
            stop=$(now)
            perl -e 'printf "%.9f\n", $ARGV[1] - $ARGV[0]' \
                "$start" "$stop" >>"$samples"
        done

        allocation_count=$(sed -n 's/.*allocations=\([0-9][0-9]*\).*/\1/p' "$stats")
        retain_count=$(sed -n 's/.*retains=\([0-9][0-9]*\).*/\1/p' "$stats")
        release_count=$(sed -n 's/.*releases=\([0-9][0-9]*\).*/\1/p' "$stats")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$variant" "$(median "$samples")" \
            "$allocation_count" "$retain_count" "$release_count"
    done
done <bench/abstractions/suite.tsv
