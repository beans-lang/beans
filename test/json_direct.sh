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

# The transcript must actually contain what the parity claim rests on: the
# broken-UTF-8 refusals ran, and the giant cases produced output.
grep -q 'ERR:invalid' "$tmp/direct.3"
grep -q '^mega1:' "$tmp/direct.3"
grep -q '^flood:' "$tmp/direct.3"
grep -q 'ok json_direct_fuzz' "$tmp/direct.3"

echo "checking a slice in the interpreter"
FUZZ_SEED=7 FUZZ_ROUNDS=40 FUZZ_GIANTS=0 \
    "$beansc" run test/cases/json_direct_fuzz.b >"$tmp/interp.direct"
FUZZ_SEED=7 FUZZ_ROUNDS=40 FUZZ_GIANTS=0 BEANS_JSON_NO_DIRECT=1 \
    "$beansc" run test/cases/json_direct_fuzz.b >"$tmp/interp.dom"
cmp "$tmp/interp.direct" "$tmp/interp.dom"

"$beansc" run test/cases/json_direct_edges.b >"$tmp/edges.interp.direct"
BEANS_JSON_NO_DIRECT=1 \
    "$beansc" run test/cases/json_direct_edges.b >"$tmp/edges.interp.dom"
cmp test/cases/json_direct_edges.out "$tmp/edges.interp.direct"
cmp "$tmp/edges.interp.direct" "$tmp/edges.interp.dom"

echo "ok json direct writer: typed edges, native/interpreter parity, refusals and giants included"
