#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runs=${BEANS_JSON_RUNS:-5}
file=${1:-build/json-typed-100mb.json}
if [[ ! -f "$file" ]]; then
    BEANS_JSON_SIZES_MB=100 BEANS_JSON_RUNS=1 \
        bash bench/json_typed_large.sh >/dev/null
fi

./build/beansc build --release bench/json_typed_large.b \
    -o build/bench_json_typed_large >/dev/null
clang -O3 -DNDEBUG -c runtime/encoding/vendor/yyjson/yyjson.c \
    -o build/json_typed_yyjson.o
clang++ -std=c++20 -O3 -DNDEBUG -I. bench/json_typed_cpp.cpp \
    build/json_typed_yyjson.o -o build/bench_json_typed_cpp
go build -o build/bench_json_typed_go bench/json_typed_go.go

echo "host: $(uname -sm)"
echo "beans: $(./build/beansc --version 2>/dev/null | head -1 || echo local)"
echo "c++: $(clang++ --version | head -1)"
echo "go: $(go version)"
echo "bun: $(bun --version)"
echo "dataset: $(wc -c <"$file") bytes"
echo "runs: $runs (median)"
echo ""

median_for() {
    local label=$1
    shift
    local samples=()
    "$@" >/dev/null
    for run in $(seq 1 "$runs"); do
        local sample="build/json-language-${label}.${run}"
        samples+=("$sample")
        "$@" >"$sample"
    done
    sed -E 's/.*nanos=([0-9]+).*/\1 &/' \
        "${samples[@]}" | \
        sort -n | sed -n "$(((runs + 1) / 2))p" | cut -d' ' -f2-
}

peak_for() {
    local label=$1
    shift
    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l "$@" >/dev/null \
            2>"build/json-language-${label}.time"
        awk '/maximum resident set size/ {print int($1 / 1024) " KiB"}' \
            "build/json-language-${label}.time"
    elif /usr/bin/time -v true >/dev/null 2>&1; then
        /usr/bin/time -v "$@" >/dev/null \
            2>"build/json-language-${label}.time"
        awk -F': ' '/Maximum resident set size/ {print $2 " KiB"}' \
            "build/json-language-${label}.time"
    fi
}

beans=$(median_for beans build/bench_json_typed_large typed "$file")
cpp=$(median_for cpp build/bench_json_typed_cpp "$file")
go_result=$(median_for go build/bench_json_typed_go "$file")
bun_result=$(median_for bun bun bench/json_typed_bun.ts "$file")

for line in "$beans" "$cpp" "$go_result" "$bun_result"; do
    records=$(sed -E 's/.*records=([0-9]+).*/\1/' <<<"$line")
    checksum=$(sed -E 's/.*checksum=([0-9]+).*/\1/' <<<"$line")
    if [[ "$records" != 1098705 || "$checksum" != 1108468234868 ]]; then
        echo "benchmark result mismatch: $line" >&2
        exit 1
    fi
done

echo "$beans peak_rss=$(peak_for beans build/bench_json_typed_large typed "$file")"
echo "$cpp peak_rss=$(peak_for cpp build/bench_json_typed_cpp "$file")"
echo "$go_result peak_rss=$(peak_for go build/bench_json_typed_go "$file")"
echo "$bun_result peak_rss=$(peak_for bun bun bench/json_typed_bun.ts "$file")"

echo ""
echo "File I/O and checksum time are excluded. Beans and C++ reject unknown,"
echo "duplicate, missing, null, and wrong-type fields. Go uses automatic"
echo "encoding/json struct decoding; it accepts unknown and duplicate fields."
echo "Bun uses JSON.parse into JavaScript objects; it has no runtime structs"
echo "and does not enforce the Beans schema."
