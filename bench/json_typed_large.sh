#!/usr/bin/env bash
set -euo pipefail

# Reproducible large JSON -> struct benchmark.
# Default data sizes are 10 MiB and 100 MiB. Opt into the soak with:
#   BEANS_JSON_SIZES_MB="10 100 1024" bash bench/json_typed_large.sh

cd "$(dirname "$0")/.."

sizes=${BEANS_JSON_SIZES_MB:-"10 100"}
runs=${BEANS_JSON_RUNS:-3}

./build/beansc build --release bench/json_typed_large.b \
    -o build/bench_json_typed_large >/dev/null
clang -O3 -DNDEBUG -I. bench/json_typed_large_handwritten.c \
    runtime/beans_rt.c -pthread \
    -o build/bench_json_typed_large_handwritten
clang -O3 -DNDEBUG -DBEANS_ARC_STATS -Wno-override-module \
    build/json_typed_large.ll build/json_typed_large_ffi.c build/beans_rt.c \
    runtime/encoding/beans_enc_json.c -pthread -lm \
    -o build/bench_json_typed_large_arc

median_line() {
    local pattern=$1
    shift
    sed -nE "/^${pattern} /s/.*nanos=([0-9]+).*/\\1 &/p" "$@" | \
        sort -n | sed -n "$(((runs + 1) / 2))p" | cut -d' ' -f2-
}

generate() {
    local mb=$1 output="build/json-typed-${mb}mb.json"
    local target=$((mb * 1024 * 1024))
    if [[ -f "$output" ]] && [[ $(wc -c <"$output") -ge $target ]]; then
        return
    fi
    python3 - "$output" "$target" <<'PY'
import sys

path, target = sys.argv[1], int(sys.argv[2])
written = 1
index = 0
with open(path, "wb") as out:
    out.write(b"[")
    while written < target - 2:
        note = "null" if index % 4 == 0 else f'"note-{index % 10000:04d}"'
        row = (
            ("," if index else "")
            + f'{{"id":{index},"userId":{index % 1000003},'
              f'"active":{"true" if index & 1 else "false"},'
              f'"score":{(index % 10000) / 100.0:.2f},'
              f'"name":"user-{index % 100000:05d}","note":{note}}}'
        ).encode()
        out.write(row)
        written += len(row)
        index += 1
    out.write(b"]")
print(f"generated {path}: {written + 1} bytes, {index} records")
PY
}

echo "host: $(uname -sm)"
for mb in $sizes; do
    generate "$mb"
    file="build/json-typed-${mb}mb.json"
    echo ""
    echo "== $mb MiB dataset ($(wc -c <"$file") bytes) =="
    for run in $(seq 1 "$runs"); do
        build/bench_json_typed_large_handwritten "$file" \
            >"build/json-typed-${mb}mb.handwritten.${run}"
    done
    median_line parse "build/json-typed-${mb}mb.handwritten."[0-9]*
    median_line handwritten_c "build/json-typed-${mb}mb.handwritten."[0-9]*
    fair=$(median_line handwritten_beans_strict \
        "build/json-typed-${mb}mb.handwritten."[0-9]*)
    echo "$fair"
    for mode in typed typed_in_place dom; do
        build/bench_json_typed_large "$mode" "$file" >/dev/null
        for run in $(seq 1 "$runs"); do
            build/bench_json_typed_large "$mode" "$file" \
                >"build/json-typed-${mb}mb.${mode}.${run}"
        done
        line=$(median_line "$mode" \
            "build/json-typed-${mb}mb.${mode}."[0-9]*)
        echo "$line"
        if [[ "$mode" == typed || "$mode" == typed_in_place ]]; then
            typed_mib=$(sed -E 's/.*mib_s=([0-9]+).*/\1/' <<<"$line")
            fair_mib=$(sed -E 's/.*mib_s=([0-9]+).*/\1/' <<<"$fair")
            awk -v mode="$mode" -v typed="$typed_mib" -v fair="$fair_mib" \
                'BEGIN { printf "%s_vs_handwritten_beans_strict=%.1f%%\n", mode, 100 * typed / fair }'
        fi
    done

    peak=""
    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l build/bench_json_typed_large typed_in_place "$file" \
            >/dev/null 2>"build/json-typed-${mb}mb.time"
        peak=$(awk '/maximum resident set size/ {print int($1 / 1024) " KiB"}' \
            "build/json-typed-${mb}mb.time")
    elif /usr/bin/time -v true >/dev/null 2>&1; then
        /usr/bin/time -v build/bench_json_typed_large typed_in_place "$file" \
            >/dev/null 2>"build/json-typed-${mb}mb.time"
        peak=$(awk -F': ' '/Maximum resident set size/ {print $2 " KiB"}' \
            "build/json-typed-${mb}mb.time")
    fi
    [[ -n "$peak" ]] && echo "typed_in_place_peak_rss=$peak"
    build/bench_json_typed_large_arc typed_in_place "$file" >/dev/null \
        2>"build/json-typed-${mb}mb.arc"
    sed -n 's/^beans arc stats: /typed_in_place_arc /p' \
        "build/json-typed-${mb}mb.arc"
done

echo ""
echo "Numbers exclude file I/O. 'parse' is yyjson only. 'handwritten_c'"
echo "is an unchecked raw C ceiling. 'handwritten_beans_strict' uses the"
echo "same Beans layout and enforces the same field and type rules as 'typed'."
echo "'dom' uses the public Value API and does manual field reads."
