#!/usr/bin/env bash
# Replays llhttp's own markdown corpus (test/fixtures/llhttp-corpus, tag
# v9.4.3, unmodified) through the beans_h1 bridge and holds its event trace
# to the upstream expectations line for line — offsets, span merging, pause
# points, error text. Every case also re-runs split in two at every byte,
# so the chunking-invariance property is part of the same gate. The case
# count is pinned: a runner that silently skips files cannot pass.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-llhttp-corpus.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

echo "checking the corpus in the native build"
"$beansc" build test/cases/llhttp_corpus_runner.b -o "$tmp/runner" >"$tmp/build.log" 2>&1
"$tmp/runner" test/fixtures/llhttp-corpus >"$tmp/native.out"
tail -1 "$tmp/native.out"
grep -q "^corpus: 253 cases, .* 0 failures$" "$tmp/native.out" || {
    echo "the corpus did not run all 253 cases cleanly" >&2
    tail -40 "$tmp/native.out" >&2
    exit 1
}

echo "checking a corpus slice in the interpreter"
# The full 21k split replays take minutes interpreted; the interpreter lane
# proves backend agreement on the whole-buffer pass by running the same
# binary events through the same Beans decoding logic.
mkdir -p "$tmp/slice/request" "$tmp/slice/response"
cp test/fixtures/llhttp-corpus/request/sample.md "$tmp/slice/request/"
cp test/fixtures/llhttp-corpus/request/transfer-encoding.md "$tmp/slice/request/"
cp test/fixtures/llhttp-corpus/response/sample.md "$tmp/slice/response/"
"$beansc" run test/cases/llhttp_corpus_runner.b -- "$tmp/slice" >"$tmp/interp.out"
tail -1 "$tmp/interp.out"
grep -q " 0 failures$" "$tmp/interp.out" || {
    echo "the interpreter corpus slice failed" >&2
    tail -40 "$tmp/interp.out" >&2
    exit 1
}

echo "ok llhttp corpus: 253 upstream cases, split-invariant, both backends"
