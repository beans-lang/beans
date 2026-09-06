#!/usr/bin/env bash
# Struct -> JSON encode throughput, and the proof the 16-byte escape scan is
# doing the work.
#
# The records shape (espresso bench3 /records: 1,000 records, ~247 KB) is what
# issue #143 measures. Its time is dominated by the per-field append and format
# machinery, not the escape scan, so the vector scan barely moves it — the
# number is reported, not floored.
#
# The scan only becomes the whole story when a document is mostly long string
# runs, so that is where the revert proof lives. Two binaries are built from
# the same emitted IR — one with the vector scan, one with BEANS_JSON_SCALAR_SCAN
# forcing the SWAR path — and the vector build must be meaningfully faster on
# the string-heavy shape. Same machine, same instant, so the ratio is immune to
# how loaded or how fast the box is; reverting the SIMD block makes the two
# binaries identical and the ratio collapses to ~1, which fails the check.
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

# What encode_into buys over the encode-then-copy shape a server takes without
# it, on the same document and the same buffer. Not a floor — the saving is a
# fraction of one route's time and the box it is measured on is shared — but
# the two numbers are taken back to back on one binary, so the gap between
# them is the string and its copies and nothing else.
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
