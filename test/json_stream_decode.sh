#!/usr/bin/env bash
# Typed JSON decoding has two engines that must decide every document
# identically: the DOM path (the default — it parses the whole document into a
# yyjson tree and walks it) and the streaming scanner
# (beans_enc_json_typed_decode_stream), which stores straight from the bytes
# with no tree and is reached by BEANS_JSON_STREAM_DECODE=1. The stream engine
# is not the default: measured against the DOM it is slower for the documents
# this benchmark decodes (many small objects, where the vendored SIMD parser
# wins), so removing the DOM does not speed the route up. It is kept and held
# to this gate because a correct alternate decoder is worth having and because
# the differential is the strongest test the typed decoder has: the two paths
# must give the same decoded values and the same accept/reject verdict with the
# same error position over a fuzz and the JSONTestSuite corpus, and the stream
# engine must actually do the work rather than defer to the DOM.
#
# Typed decoding is native only: the tree interpreter has no typed-decode entry
# (json.decode<T> returns kind "unsupported" there), so this gate, like the
# typed cases in encoding.sh, runs the native build.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-json-stream.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

# 1. The whole-document depth guarantee, including values nested past the limit
#    under a field the schema does not name (issue #142). The default (DOM) must
#    match the golden, and the stream engine must match the DOM.
echo "checking the depth policy reaches values under unknown keys"
"$beansc" build test/cases/encoding_json_typed_depth_unknown.b \
    -o "$tmp/depth" >/dev/null
"$tmp/depth" >"$tmp/depth.dom"
BEANS_JSON_STREAM_DECODE=1 "$tmp/depth" >"$tmp/depth.stream"
diff -u test/cases/encoding_json_typed_depth_unknown.out "$tmp/depth.dom"
diff -u "$tmp/depth.dom" "$tmp/depth.stream"

# 2. Differential fuzz: the stream engine against the DOM over round-tripped
#    values across every schema shape, hand-built edge documents, option
#    combinations, and every truncation and byte flip of a valid document. The
#    two transcripts must be byte-identical — same decoded values, and the same
#    error code, byte offset and field index on every refusal — and on the
#    stream run the engine must have decoded every valid document itself
#    (FALLBACKS:0).
echo "checking the stream engine and the DOM agree over the fuzz"
"$beansc" build test/cases/json_stream_fuzz.b -o "$tmp/fuzz" >/dev/null
for seed in 20260906 3 99999 1; do
    FUZZ_SEED=$seed FUZZ_ROUNDS=400 "$tmp/fuzz" >"$tmp/fuzz.dom.$seed"
    FUZZ_SEED=$seed FUZZ_ROUNDS=400 BEANS_JSON_STREAM_DECODE=1 \
        "$tmp/fuzz" >"$tmp/fuzz.stream.$seed"
    cmp "$tmp/fuzz.dom.$seed" "$tmp/fuzz.stream.$seed"
    grep -q '^FALLBACKS:0$' "$tmp/fuzz.stream.$seed" || {
        echo "the stream engine fell back to the DOM on a valid document" >&2
        grep '^FALLBACKS:' "$tmp/fuzz.stream.$seed" >&2
        exit 1
    }
done
# The transcript must actually contain the error variety the parity rests on.
grep -q 'code=108' "$tmp/fuzz.dom.20260906"    # depth, under an unknown key
grep -q 'code=106' "$tmp/fuzz.dom.20260906"    # a missing required field
grep -q 'code=2 pos=' "$tmp/fuzz.dom.20260906" # truncation, an EOF at an offset
grep -q 'go😀odA' "$tmp/fuzz.dom.20260906"      # a surrogate pair unescaped

# 3. The JSONTestSuite corpus (github.com/nst/JSONTestSuite, MIT), vendored
#    under test/corpus/jsontestsuite. Every y_/n_/i_ file, decoded as a
#    permissive object shape and a permissive list shape, must give the same
#    verdict and the same error position on both engines, and the stream engine
#    must have decoded every file it accepts.
echo "checking the stream engine and the DOM agree over JSONTestSuite"
corpus_dir=test/corpus/jsontestsuite
corpus_files=$(find "$corpus_dir" -name '*.json' | wc -l | tr -d ' ')
if [[ "$corpus_files" -lt 300 ]]; then
    echo "JSONTestSuite corpus is missing ($corpus_files files under $corpus_dir)" >&2
    exit 1
fi
"$beansc" build test/cases/json_stream_corpus_runner.b -o "$tmp/corpus" >/dev/null
"$tmp/corpus" "$corpus_dir" >"$tmp/corpus.dom"
BEANS_JSON_STREAM_DECODE=1 "$tmp/corpus" "$corpus_dir" >"$tmp/corpus.stream"
cmp "$tmp/corpus.dom" "$tmp/corpus.stream"
grep -q '^FALLBACKS:0$' "$tmp/corpus.stream" || {
    echo "the stream engine fell back to the DOM on a corpus document" >&2
    grep '^FALLBACKS:' "$tmp/corpus.stream" >&2
    exit 1
}
processed=$(grep -c ':obj ' "$tmp/corpus.dom")
if [[ "$processed" -ne "$corpus_files" ]]; then
    echo "corpus runner read $processed of $corpus_files files" >&2
    exit 1
fi

echo "ok json stream decode: depth policy, differential fuzz, JSONTestSuite ($corpus_files files)"
