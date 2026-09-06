#!/usr/bin/env bash
# Typed JSON decoding — `json.decode<T>`, `decode_bytes`, `decode_bytes_in_place`
# and `decode_with_options` — has one engine: the document is parsed by the
# vendored yyjson reader and the resulting tree is walked straight into the
# target structs. There is no second implementation to diff it against, so this
# gate stands in for one three ways:
#
#  1. An external answer sheet. The JSONTestSuite parsing corpus
#     (github.com/nst/JSONTestSuite, MIT), vendored under
#     test/corpus/jsontestsuite, classifies every file by its name: `y_` must be
#     accepted by any conforming parser, `n_` must be rejected, `i_` is left to
#     the implementation. The runner asserts that answer sheet in the only terms
#     a typed decoder can honour it — a `y_` file may be refused for its SHAPE
#     but never for its SYNTAX, and an `n_` file must be refused for its syntax
#     — and records every verdict, error code and byte offset in a golden.
#  2. Properties the decoder must have on its own: a round-tripped value decodes
#     back to the same bytes, an accepted document's encoding is a fixed point,
#     and every proper prefix of a valid document is refused.
#  3. Goldens. The exact error code and byte offset of every refusal, per corpus
#     file and per fuzz seed, is checked in — so a change in behaviour is loud
#     even where no property is violated.
#
# Everything runs under ASan/UBSan as well, in both allocator modes (pooled and
# BEANS_NO_POOL=1), because the decode path writes decoded payloads into
# allocator blocks that are deliberately not pre-zeroed (beans_alloc_bytes) and
# rewrites the caller's buffer in place for decode_bytes_in_place.
#
# Typed decoding is native only: the tree interpreter has no typed-decode entry
# (json.decode<T> returns kind "unsupported" there), so this gate, like the
# typed cases in encoding.sh, runs the native build. That gap is pre-existing
# and is not closed here.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-json-typed.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
beansc=${BEANSC:-./build/beansc}

fuzz_seeds=(20260906 3 99999 1)
fuzz_rounds=400

# 1. The whole-document depth guarantee, including values nested past the limit
#    under a field the schema does not name (issue #142).
echo "checking the depth policy reaches values under unknown keys"
"$beansc" build test/cases/encoding_json_typed_depth_unknown.b \
    -o "$tmp/depth" >/dev/null
"$tmp/depth" >"$tmp/depth.out"
diff -u test/cases/encoding_json_typed_depth_unknown.out "$tmp/depth.out"

# 2. The invariant fuzz. Each seed's transcript is a golden: the decoded value
#    re-encoded, and for every refusal the error code, byte offset and field
#    index the request buffer held. The invariants are checked inside the
#    program, so a violation is named as well as diffed.
echo "checking the decode invariants over the fuzz"
"$beansc" build test/cases/json_typed_decode_fuzz.b -o "$tmp/fuzz" >/dev/null
for seed in "${fuzz_seeds[@]}"; do
    FUZZ_SEED=$seed FUZZ_ROUNDS=$fuzz_rounds "$tmp/fuzz" >"$tmp/fuzz.$seed"
    diff -u "test/cases/json_typed_decode_fuzz.$seed.out" "$tmp/fuzz.$seed"
    grep -q ' violations=0$' "$tmp/fuzz.$seed" || {
        echo "the fuzz reported invariant violations for seed $seed" >&2
        grep '^VIOLATION' "$tmp/fuzz.$seed" >&2
        exit 1
    }
done
# The transcript must actually contain the error variety the goldens rest on:
# without these the diff would be pinning a much weaker run than it claims.
grep -q 'code=108' "$tmp/fuzz.20260906"    # depth, under an unknown key
grep -q 'code=106' "$tmp/fuzz.20260906"    # a missing required field
grep -q 'code=2 pos=' "$tmp/fuzz.20260906" # truncation, an EOF at an offset
grep -q 'go😀odA' "$tmp/fuzz.20260906"      # a surrogate pair unescaped
grep -q 'truncations=' "$tmp/fuzz.20260906"

# 3. The JSONTestSuite corpus as an answer sheet, plus its golden.
echo "checking typed decoding against the JSONTestSuite answer sheet"
corpus_dir=test/corpus/jsontestsuite
corpus_files=$(find "$corpus_dir" -name '*.json' | wc -l | tr -d ' ')
if [[ "$corpus_files" -lt 300 ]]; then
    echo "JSONTestSuite corpus is missing ($corpus_files files under $corpus_dir)" >&2
    exit 1
fi
"$beansc" build test/cases/json_typed_corpus_runner.b -o "$tmp/corpus" >/dev/null
"$tmp/corpus" "$corpus_dir" >"$tmp/corpus.out"
diff -u test/cases/json_typed_corpus.out "$tmp/corpus.out"
grep -q ' violations=0$' "$tmp/corpus.out" || {
    echo "the corpus runner reported answer-sheet violations" >&2
    grep '^VIOLATION' "$tmp/corpus.out" >&2
    exit 1
}
# Every file must have been read, in all three shapes: a runner that silently
# skipped files would otherwise pass on a shrunken corpus.
for shape in obj arr ipl; do
    processed=$(grep -c ":$shape " "$tmp/corpus.out")
    if [[ "$processed" -ne "$corpus_files" ]]; then
        echo "corpus runner produced $processed $shape verdicts for $corpus_files files" >&2
        exit 1
    fi
done
# And the answer sheet's own tally must match the files on disk, so a corpus
# that lost its y_/n_ files cannot pass with only i_ files left.
answer_line=$(grep '^ANSWERSHEET ' "$tmp/corpus.out")
for class in y n i; do
    on_disk=$(find "$corpus_dir" -name "${class}_*.json" | wc -l | tr -d ' ')
    counted=$(sed -n "s/.* $class=\([0-9]*\).*/\1/p" <<<"$answer_line")
    if [[ "$counted" != "$on_disk" ]]; then
        echo "answer sheet counted $counted ${class}_ files, $on_disk are on disk" >&2
        exit 1
    fi
done

# 4. A decoded string must still be a C string.
#
#    Every Beans string is allocated one byte longer than its length because
#    the runtime hands the pointer straight to C — beans_file_open, lstat and
#    open all take one as a `char*`. Nothing inside the language reads that
#    byte, since a string's length lives in its allocation header, so no
#    amount of decoding, printing or re-encoding above can tell a terminated
#    string from an unterminated one. The decoder used to get the terminator
#    for free from beans_alloc, which zeroes a recycled block; it now uses
#    beans_alloc_bytes, which deliberately does not, and writes the terminator
#    itself. This is what holds it to that.
#
#    A missing terminator is only visible when the byte it should occupy is
#    not already zero, so the case decodes a LONGER string of the same size
#    class first and lets it drop: the pool recycles that block without
#    zeroing it, leaving the long string's characters where the short string's
#    terminator belongs. That also means BEANS_NO_POOL=1 cannot see this — its
#    blocks all come from a zeroing allocator — which is why this runs pooled
#    and why the golden records the size class each path exercised. The path
#    lengths below span three classes.
echo "checking a decoded string is still a C string"
"$beansc" build test/cases/encoding_json_typed_cstring.b -o "$tmp/cstring" >/dev/null
probe_dir=build/json_nul_probe
rm -rf "$probe_dir"
mkdir -p "$probe_dir"
repeat_char() {
    local want=$1 char=$2 out=''
    while [[ ${#out} -lt $want ]]; do out+="$char"; done
    printf '%s' "$out"
}
: >"$tmp/cstring.out"
for stem_len in 1 6 10 17 27; do
    target="$probe_dir/$(repeat_char "$stem_len" f).t"
    length=${#target}
    # A path whose length is 15 mod 16 fills its class exactly, so no longer
    # string of the same class exists to prime the block with — the case would
    # pass whatever the decoder did. Refuse rather than pretend to test.
    if [[ $(( length % 16 )) -eq 15 ]]; then
        echo "path $target (length $length) fills its size class; no primer" \
             "can reach past it, so this case would prove nothing" >&2
        exit 1
    fi
    total=$(( (32 + length) & ~15 ))
    primer_len=$(( total - 16 - 1 ))
    printf 'hello' >"$target"
    printf '{"s":"%s"}' "$(repeat_char "$primer_len" X)" >"$tmp/cstring.prime"
    printf '{"s":"%s"}' "$target" >"$tmp/cstring.path"
    echo "path length $length in size class $total, primed with $primer_len" \
        >>"$tmp/cstring.out"
    "$tmp/cstring" "$tmp/cstring.prime" "$tmp/cstring.path" >>"$tmp/cstring.out"
done
diff -u test/cases/encoding_json_typed_cstring.out "$tmp/cstring.out"
# More than one size class must have been exercised: a run that collapsed onto
# a single class would be a much weaker test than the golden claims.
classes=$(sed -n 's/.*in size class \([0-9]*\),.*/\1/p' "$tmp/cstring.out" \
    | sort -u | wc -l | tr -d ' ')
if [[ "$classes" -lt 3 ]]; then
    echo "the C-string check covered $classes size classes, expected 3" >&2
    exit 1
fi
rm -rf "$probe_dir"

# 5. ASan/UBSan over both, in both allocator modes. The emitted IR, the runtime
#    and the same bridge source the driver compiles are instrumented together,
#    exactly as encoding.sh does it.
echo "checking the decoder under ASan/UBSan, pooled and unpooled"
san_flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined
           -Wno-override-module)
clang "${san_flags[@]}" -c runtime/encoding/beans_enc_json.c -o "$tmp/san_json.o"
for case_name in json_typed_decode_fuzz json_typed_corpus_runner; do
    ffi_side="build/${case_name}_ffi.c"
    if [[ ! -f "$ffi_side" ]]; then
        echo "no FFI sidecar build/${case_name}_ffi.c: the extern \"C\" probe" \
             "is gone, so the goldens no longer carry error codes" >&2
        exit 1
    fi
    clang "${san_flags[@]}" "build/$case_name.ll" "$ffi_side" build/beans_rt.c \
        "$tmp/san_json.o" -lm -o "$tmp/$case_name.san"
done
for pool in pooled nopool; do
    env_args=()
    [[ "$pool" == "nopool" ]] && env_args=(BEANS_NO_POOL=1)
    seed=${fuzz_seeds[0]}
    if ! env "${env_args[@]}" FUZZ_SEED=$seed FUZZ_ROUNDS=$fuzz_rounds \
            "$tmp/json_typed_decode_fuzz.san" \
            >"$tmp/fuzz.san.$pool" 2>"$tmp/fuzz.san.$pool.err"; then
        cat "$tmp/fuzz.san.$pool.err" >&2
        echo "the fuzz failed under ASan/UBSan ($pool)" >&2
        exit 1
    fi
    if ! env "${env_args[@]}" "$tmp/json_typed_corpus_runner.san" "$corpus_dir" \
            >"$tmp/corpus.san.$pool" 2>"$tmp/corpus.san.$pool.err"; then
        cat "$tmp/corpus.san.$pool.err" >&2
        echo "the corpus runner failed under ASan/UBSan ($pool)" >&2
        exit 1
    fi
    # A sanitizer can report without failing the run (ASan's abort_on_error=0,
    # UBSan's non-fatal checks), so the captured stderr is inspected too. Each
    # grep names its capture file literally rather than building the name from
    # a loop variable: test/sanitizer_gates.sh traces every such grep back to
    # the `2>` that writes the file, and a name it cannot trace is a check
    # nothing proves is reachable.
    if grep -Eq "AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer" \
        "$tmp/fuzz.san.$pool.err"; then
        cat "$tmp/fuzz.san.$pool.err" >&2
        echo "the fuzz reported a sanitizer error ($pool)" >&2
        exit 1
    fi
    if grep -Eq "AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer" \
        "$tmp/corpus.san.$pool.err"; then
        cat "$tmp/corpus.san.$pool.err" >&2
        echo "the corpus runner reported a sanitizer error ($pool)" >&2
        exit 1
    fi
    # The instrumented build must reach the same answers as the shipped one.
    diff -u "test/cases/json_typed_decode_fuzz.$seed.out" "$tmp/fuzz.san.$pool"
    diff -u test/cases/json_typed_corpus.out "$tmp/corpus.san.$pool"
done

echo "ok json typed decode: depth policy, invariant fuzz (${#fuzz_seeds[@]} seeds), JSONTestSuite ($corpus_files files), C-string terminator across $classes size classes, ASan/UBSan in both pool modes"
