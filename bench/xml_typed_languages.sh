#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runs=${BEANS_XML_RUNS:-5}
size_mb=${BEANS_XML_SIZE_MB:-100}
file=${1:-build/xml-typed-100mb.xml}
beansc=${BEANSC:-./build/beansc}

generate() {
    local output=$1 target=$2
    if [[ -f "$output" ]] && [[ $(wc -c <"$output") -eq $target ]]; then
        return
    fi
    python3 - "$output" "$target" <<'PY'
import sys

path, target = sys.argv[1], int(sys.argv[2])
opening = b"<rows>"
closing = b"</rows>"
written = len(opening)
index = 0
checksum = 0
with open(path, "wb") as out:
    out.write(opening)
    while True:
        name = f"user-{index % 100000:05d}"
        note = "" if index % 4 == 0 else f"<note>note-{index % 10000:04d}</note>"
        row = (
            f'<row id="{index}" userId="{index % 1000003}">'
            f'<active>{"true" if index & 1 else "false"}</active>'
            f'<score>{(index % 10000) / 100.0:.2f}</score>'
            f'<name>{name}</name>{note}</row>'
        ).encode()
        if written + len(row) + len(closing) > target:
            break
        out.write(row)
        written += len(row)
        checksum += index + index % 1000003 + len(name) + (index & 1)
        if index % 4 != 0:
            checksum += len(f"note-{index % 10000:04d}")
        index += 1
    out.write(b" " * (target - written - len(closing)))
    out.write(closing)
print(f"generated {path}: {target} bytes, {index} records, checksum {checksum}")
PY
}

if [[ ! -f "$file" ]]; then
    mkdir -p build
    generate "$file" $((size_mb * 1024 * 1024))
fi

"$beansc" build --release bench/xml_typed_large.b \
    -o build/bench_xml_typed_large >/dev/null
clang++ -std=c++20 -O3 -DNDEBUG -DPUGIXML_NO_XPATH -I. \
    bench/xml_typed_cpp.cpp runtime/encoding/vendor/pugixml/pugixml.cpp \
    -o build/bench_xml_typed_cpp
go build -o build/bench_xml_typed_go bench/xml_typed_go.go
if [[ ! -f bench/xml_bun/bun.lock ]]; then
    bun install --cwd bench/xml_bun >/dev/null
else
    bun install --cwd bench/xml_bun --frozen-lockfile >/dev/null
fi

echo "host: $(uname -sm)"
echo "beans: $($beansc --version 2>/dev/null | head -1 || echo local)"
echo "c++: $(clang++ --version | head -1)"
echo "go: $(go version)"
echo "bun: $(bun --version)"
echo "fast-xml-parser: 5.10.1"
echo "dataset: $(wc -c <"$file") bytes"
echo "runs: $runs (median)"
echo ""

median_for() {
    local label=$1
    shift
    local samples=()
    "$@" >/dev/null
    for run in $(seq 1 "$runs"); do
        local sample="build/xml-language-${label}.${run}"
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
            2>"build/xml-language-${label}.time"
        awk '/maximum resident set size/ {print int($1 / 1024) " KiB"}' \
            "build/xml-language-${label}.time"
    elif /usr/bin/time -v true >/dev/null 2>&1; then
        /usr/bin/time -v "$@" >/dev/null \
            2>"build/xml-language-${label}.time"
        awk -F': ' '/Maximum resident set size/ {print $2 " KiB"}' \
            "build/xml-language-${label}.time"
    fi
}

beans=$(median_for beans build/bench_xml_typed_large "$file")
beans_in_place=$(median_for beans-in-place \
    build/bench_xml_typed_large "$file" in_place)
cpp=$(median_for cpp build/bench_xml_typed_cpp "$file")
go_result=$(median_for go build/bench_xml_typed_go "$file")
bun_result=$(median_for bun bun bench/xml_bun/xml_typed_bun.ts "$file")

expected_records=$(sed -E 's/.*records=([0-9]+).*/\1/' <<<"$beans")
expected_checksum=$(sed -E 's/.*checksum=([0-9]+).*/\1/' <<<"$beans")
for line in "$beans" "$beans_in_place" "$cpp" "$go_result" "$bun_result"; do
    records=$(sed -E 's/.*records=([0-9]+).*/\1/' <<<"$line")
    checksum=$(sed -E 's/.*checksum=([0-9]+).*/\1/' <<<"$line")
    if [[ "$records" != "$expected_records" || \
          "$checksum" != "$expected_checksum" ]]; then
        echo "benchmark result mismatch: $line" >&2
        exit 1
    fi
done

echo "$beans peak_rss=$(peak_for beans build/bench_xml_typed_large "$file")"
echo "$beans_in_place peak_rss=$(peak_for beans-in-place \
    build/bench_xml_typed_large "$file" in_place)"
echo "$cpp peak_rss=$(peak_for cpp build/bench_xml_typed_cpp "$file")"
echo "$go_result peak_rss=$(peak_for go build/bench_xml_typed_go "$file")"
echo "$bun_result peak_rss=$(peak_for bun bun bench/xml_bun/xml_typed_bun.ts "$file")"

echo ""
echo "File I/O and checksum time are excluded. Beans and C++ enforce the"
echo "same scalar schema. Go encoding/xml and Bun fast-xml-parser use their"
echo "normal automatic mapping and accept schema details that Beans rejects."
