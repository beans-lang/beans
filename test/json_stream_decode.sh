#!/usr/bin/env bash
# Typed JSON decoding runs a streaming scanner that stores straight into the
# target structs, with no intermediate yyjson DOM (issue #144), and folds the
# whole-document depth guarantee into that single pass (issue #142). The DOM
# path is kept behind BEANS_JSON_NO_DIRECT_DECODE as the reference. This gate
# proves the stream path and the DOM path agree on every document — the same
# decoded values, and the same accept/reject verdict with the same error
# position — over a differential fuzz and the JSONTestSuite corpus, and that
# the stream engine actually did the work rather than deferring to the DOM.
#
# Typed decoding is a native-only fast path today: the tree interpreter has no
# typed-decode entry (json.decode<T> returns kind "unsupported" there), so this
# gate, like the typed cases in encoding.sh, runs the native build only.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-json-stream.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

# 1. The whole-document depth guarantee, including values nested past the
#    limit under a field the schema does not name (issue #142). This must give
#    the same verdict on the stream path and the DOM path.
echo "checking the depth policy reaches values under unknown keys"
"$beansc" build test/cases/encoding_json_typed_depth_unknown.b \
    -o "$tmp/depth" >/dev/null
"$tmp/depth" >"$tmp/depth.stream"
BEANS_JSON_NO_DIRECT_DECODE=1 "$tmp/depth" >"$tmp/depth.dom"
diff -u test/cases/encoding_json_typed_depth_unknown.out "$tmp/depth.stream"
diff -u "$tmp/depth.stream" "$tmp/depth.dom"

# 2. Differential fuzz: the stream path against the DOM path over round-tripped
#    values across every schema shape, hand-built edge documents, option
#    combinations, and every truncation and byte flip of a valid document. The
#    two transcripts must be byte-identical — same decoded values, and the same
#    error code, byte offset and field index on every refusal — and the stream
#    engine must have decoded every valid document itself (FALLBACKS:0).
echo "checking the stream path and the DOM path agree over the fuzz"
"$beansc" build test/cases/json_stream_fuzz.b -o "$tmp/fuzz" >/dev/null
for seed in 20260906 3 99999 1; do
    FUZZ_SEED=$seed FUZZ_ROUNDS=400 "$tmp/fuzz" >"$tmp/fuzz.stream.$seed"
    FUZZ_SEED=$seed FUZZ_ROUNDS=400 BEANS_JSON_NO_DIRECT_DECODE=1 \
        "$tmp/fuzz" >"$tmp/fuzz.dom.$seed"
    cmp "$tmp/fuzz.stream.$seed" "$tmp/fuzz.dom.$seed"
    grep -q '^FALLBACKS:0$' "$tmp/fuzz.stream.$seed" || {
        echo "the stream engine fell back to the DOM on a valid document" >&2
        grep '^FALLBACKS:' "$tmp/fuzz.stream.$seed" >&2
        exit 1
    }
done
# The transcript must actually contain the error variety the parity rests on:
# parse errors with byte offsets and typed errors with field indices.
grep -q 'code=108' "$tmp/fuzz.stream.20260906"   # depth, under an unknown key
grep -q 'code=106' "$tmp/fuzz.stream.20260906"   # a missing required field
grep -q 'code=2 pos=' "$tmp/fuzz.stream.20260906" # truncation, an EOF at an offset
grep -q 'go😀odA' "$tmp/fuzz.stream.20260906"     # a surrogate pair unescaped

# 3. The JSONTestSuite corpus (github.com/nst/JSONTestSuite, MIT), vendored
#    under test/corpus/jsontestsuite. Every y_/n_/i_ file, decoded as a
#    permissive object shape and a permissive list shape, must give the same
#    accept/reject verdict and the same error position on the stream path and
#    the DOM path, and the stream engine must have decoded every accepted file.
echo "checking the stream path and the DOM path agree over JSONTestSuite"
corpus_dir=test/corpus/jsontestsuite
corpus_files=$(find "$corpus_dir" -name '*.json' | wc -l | tr -d ' ')
if [[ "$corpus_files" -lt 300 ]]; then
    echo "JSONTestSuite corpus is missing ($corpus_files files under $corpus_dir)" >&2
    exit 1
fi
"$beansc" build test/cases/json_stream_corpus_runner.b -o "$tmp/corpus" >/dev/null
"$tmp/corpus" "$corpus_dir" >"$tmp/corpus.stream"
BEANS_JSON_NO_DIRECT_DECODE=1 "$tmp/corpus" "$corpus_dir" >"$tmp/corpus.dom"
cmp "$tmp/corpus.stream" "$tmp/corpus.dom"
grep -q '^FALLBACKS:0$' "$tmp/corpus.stream" || {
    echo "the stream engine fell back to the DOM on a corpus document" >&2
    grep '^FALLBACKS:' "$tmp/corpus.stream" >&2
    exit 1
}
# The runner must actually have read every file, not skipped a moved layout.
processed=$(grep -c ':obj ' "$tmp/corpus.stream")
if [[ "$processed" -ne "$corpus_files" ]]; then
    echo "corpus runner read $processed of $corpus_files files" >&2
    exit 1
fi
echo "ok json stream decode: depth policy, differential fuzz, JSONTestSuite ($corpus_files files)"
