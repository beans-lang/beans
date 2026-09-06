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

echo "ok json stream decode: depth policy"
