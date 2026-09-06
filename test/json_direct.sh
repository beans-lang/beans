#!/usr/bin/env bash
# The direct compact JSON writer must be byte-identical to the yyjson DOM
# path it replaced — same bytes on success, same refusal on broken UTF-8.
# The fuzz drives both writers over the same seeded values (escapes, control
# bytes, unicode, integer extrema, optionals present and absent, boxed
# options, growth-boundary and megabyte strings, fifty-thousand-element
# lists, deep nesting, root lists) and this script compares the transcripts.
# BEANS_JSON_NO_DIRECT is the lever that routes everything through the DOM.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-json-direct.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

echo "checking typed list edge cases against their exact output"
"$beansc" build test/cases/json_direct_edges.b -o "$tmp/edges" >/dev/null
"$tmp/edges" >"$tmp/edges.direct"
BEANS_JSON_NO_DIRECT=1 "$tmp/edges" >"$tmp/edges.dom"
cmp "$tmp/edges.direct" "$tmp/edges.dom"
cmp test/cases/json_direct_edges.out "$tmp/edges.direct"

echo "checking the writers agree byte for byte in the native build"
"$beansc" build test/cases/json_direct_fuzz.b -o "$tmp/fuzz" >/dev/null
for seed in 3 20260821; do
    FUZZ_SEED=$seed FUZZ_ROUNDS=1500 \
        "$tmp/fuzz" >"$tmp/direct.$seed"
    FUZZ_SEED=$seed FUZZ_ROUNDS=1500 BEANS_JSON_NO_DIRECT=1 \
        "$tmp/fuzz" >"$tmp/dom.$seed"
    cmp "$tmp/direct.$seed" "$tmp/dom.$seed"
done
# Every seeded value is also re-encoded with encode_into into an empty Bytes
# and into one already holding a prefix, then compared against encode: the
# appended bytes, the returned count, the untouched prefix, and a shared
# refusal must all agree. The fuzz counts the mismatches and exits non-zero if
# any value disagrees or no check ran, so a broken encode_into fails the runs
# above under `set -e` — no transcript grep, which trips over the raw control
# and multibyte bytes these documents carry.

# The transcript must still contain what the parity claim rests on: the
# broken-UTF-8 refusals ran, the giant cases produced output, and encode_into
# was exercised. LC_ALL=C grep -a keeps grep out of the binary mode those raw
# bytes would otherwise trigger.
LC_ALL=C grep -aq 'ERR:invalid' "$tmp/direct.3"
LC_ALL=C grep -aq '^mega1:' "$tmp/direct.3"
LC_ALL=C grep -aq '^flood:' "$tmp/direct.3"
LC_ALL=C grep -aq 'into: checks=[1-9][0-9]* mismatches=0' "$tmp/direct.3"
LC_ALL=C grep -aq 'ok json_direct_fuzz' "$tmp/direct.3"

echo "checking a slice in the interpreter"
FUZZ_SEED=7 FUZZ_ROUNDS=40 FUZZ_GIANTS=0 \
    "$beansc" run test/cases/json_direct_fuzz.b >"$tmp/interp.direct"
FUZZ_SEED=7 FUZZ_ROUNDS=40 FUZZ_GIANTS=0 BEANS_JSON_NO_DIRECT=1 \
    "$beansc" run test/cases/json_direct_fuzz.b >"$tmp/interp.dom"
cmp "$tmp/interp.direct" "$tmp/interp.dom"

# The interpreter and the native backend must agree byte for byte — on encode
# and on encode_into, refusals included. The suite never compared the two
# directly before, which is how the interpreter came to emit invalid UTF-8 the
# native writers reject. Giants off so both sides emit the same set; the
# ERR:invalid check proves the refusal path is actually in the compared runs.
echo "checking native and interpreter agree byte for byte"
for seed in 3 20260821; do
    FUZZ_SEED=$seed FUZZ_ROUNDS=150 FUZZ_GIANTS=0 \
        "$tmp/fuzz" >"$tmp/cross.native.$seed"
    FUZZ_SEED=$seed FUZZ_ROUNDS=150 FUZZ_GIANTS=0 \
        "$beansc" run test/cases/json_direct_fuzz.b >"$tmp/cross.interp.$seed"
    cmp "$tmp/cross.native.$seed" "$tmp/cross.interp.$seed"
    LC_ALL=C grep -aq 'ERR:invalid' "$tmp/cross.native.$seed"
done

"$beansc" run test/cases/json_direct_edges.b >"$tmp/edges.interp.direct"
BEANS_JSON_NO_DIRECT=1 \
    "$beansc" run test/cases/json_direct_edges.b >"$tmp/edges.interp.dom"
cmp test/cases/json_direct_edges.out "$tmp/edges.interp.direct"
cmp "$tmp/edges.interp.direct" "$tmp/edges.interp.dom"

echo "ok json direct writer: typed edges, native/interpreter parity, refusals and giants included"
