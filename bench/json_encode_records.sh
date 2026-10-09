#!/usr/bin/env bash
# Struct -> JSON encode throughput, and the proof the 16-byte escape scan is
# doing the work.
#
# The records shape measures issue #143; field formatting dominates, so report
# its result without a performance floor.
#
# Compare vector and SWAR scans from the same IR on a string-heavy input. The
# same-run ratio must exceed the floor; reverting SIMD makes it fail.
set -euo pipefail
cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
rounds=${ROUNDS:-400}

"$beansc" build --release --cpu native bench/json_encode_records.b \
    -o build/bench_json_encode_records >/dev/null

ll=build/json_encode_records.ll
ffi=build/json_encode_records_ffi.c
[[ -f "$ffi" ]] || ffi=""
common=(-O3 -Wno-override-module "$ll" $ffi build/beans_rt.c
        runtime/encoding/beans_enc_json.c -pthread -lm)
clang "${common[@]}" -o build/bench_json_encode_records_simd
clang -DBEANS_JSON_SCALAR_SCAN "${common[@]}" \
    -o build/bench_json_encode_records_scalar

echo "== records shape (reported; scan is not this shape's bottleneck) =="
records_simd=$(ROUNDS="$rounds" MODE=records \
    build/bench_json_encode_records_simd)
records_scalar=$(ROUNDS="$rounds" MODE=records \
    build/bench_json_encode_records_scalar)
echo "  vector: $records_simd"
echo "  scalar: $records_scalar"

# The output of both binaries must be byte-for-byte the same JSON: the scan
# changes speed, never bytes. The fnv1a64 the bench prints is that check.
simd_fnv=$(sed -E 's/.*fnv1a64=([0-9]+).*/\1/' <<<"$records_simd")
scalar_fnv=$(sed -E 's/.*fnv1a64=([0-9]+).*/\1/' <<<"$records_scalar")
if [[ "$simd_fnv" != "$scalar_fnv" ]]; then
    echo "vector and scalar scans produced different bytes ($simd_fnv vs $scalar_fnv)" >&2
    exit 1
fi

# Compare encode_into with encode-then-copy on the same document and buffer.
# Both timings use one binary, so the difference isolates the string copies.
echo "== encode + copy into a buffer, against encode_into =="
records_copy=$(ROUNDS="$rounds" MODE=copy \
    build/bench_json_encode_records_simd)
echo "  encode+copy: $records_copy"
echo "  encode_into: $records_simd"
copy_fnv=$(sed -E 's/.*fnv1a64=([0-9]+).*/\1/' <<<"$records_copy")
if [[ "$copy_fnv" != "$simd_fnv" ]]; then
    echo "encode and encode_into produced different bytes ($copy_fnv vs $simd_fnv)" >&2
    exit 1
fi
# encode_into removes a large allocation and two copies, so its same-run ratio
# must be at least 1.00x. This relative floor tolerates shared-machine noise.
copy_mgbps=$(sed -E 's/.*gbps_milli=([0-9]+).*/\1/' <<<"$records_copy")
records_mgbps=$(sed -E 's/.*gbps_milli=([0-9]+).*/\1/' <<<"$records_simd")
echo "  encode_into ${records_mgbps} milli-GB/s vs encode+copy ${copy_mgbps} milli-GB/s (need >= ${copy_mgbps})"
if [[ "$records_mgbps" -lt "$copy_mgbps" ]]; then
    echo "encode_into is slower than the encode-then-copy shape it replaces" >&2
    exit 1
fi

# Report the former DOM path (DOM construction plus yyjson writing) for context.
# Its narrow gap on short fields is too small for a stable performance floor.
records_dom=$(ROUNDS="$rounds" MODE=records BEANS_JSON_NO_DIRECT=1 \
    build/bench_json_encode_records_simd)
echo "  DOM path (yyjson doc + write): $records_dom"
dom_fnv=$(sed -E 's/.*fnv1a64=([0-9]+).*/\1/' <<<"$records_dom")
if [[ "$dom_fnv" != "$simd_fnv" ]]; then
    echo "the direct writer and the DOM path produced different bytes" >&2
    exit 1
fi

echo "== string-heavy shape (the scan is the work here) =="
strings_simd=$(MODE=strings ROUNDS="$rounds" build/bench_json_encode_records_simd)
strings_scalar=$(MODE=strings ROUNDS="$rounds" \
    build/bench_json_encode_records_scalar)
echo "  vector: $strings_simd"
echo "  scalar: $strings_scalar"
simd_mgbps=$(sed -E 's/.*gbps_milli=([0-9]+).*/\1/' <<<"$strings_simd")
scalar_mgbps=$(sed -E 's/.*gbps_milli=([0-9]+).*/\1/' <<<"$strings_scalar")
strings_simd_fnv=$(sed -E 's/.*fnv1a64=([0-9]+).*/\1/' <<<"$strings_simd")
strings_scalar_fnv=$(sed -E 's/.*fnv1a64=([0-9]+).*/\1/' <<<"$strings_scalar")
if [[ "$strings_simd_fnv" != "$strings_scalar_fnv" ]]; then
    echo "vector and scalar scans produced different bytes on the string shape" >&2
    exit 1
fi

# The measured gap is ~1.7x on this shape; 1.3x is the floor, well clear of
# both machine noise and a reverted (scan-identical) build's ~1.0x.
threshold=$((scalar_mgbps * 13 / 10))
echo "  vector ${simd_mgbps} milli-GB/s vs scalar ${scalar_mgbps} milli-GB/s (need >= ${threshold})"
if [[ "$simd_mgbps" -lt "$threshold" ]]; then
    echo "the 16-byte escape scan is not carrying the string-heavy shape" >&2
    echo "(vector build no faster than the SWAR build — is the SIMD path live?)" >&2
    exit 1
fi

echo "ok json encode records: writer throughput reported, 16-byte scan proven on the string shape"
