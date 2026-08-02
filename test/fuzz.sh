#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
seconds=${1:-15}
case "$seconds" in
    ''|*[!0-9]*) echo "fuzz duration must be whole seconds" >&2; exit 2 ;;
esac
if [[ "$seconds" -lt 1 ]]; then
    echo "fuzz duration must be positive" >&2
    exit 2
fi

corpus=build/fuzz-corpus
mkdir -p "$corpus"
cp test/cases/*.b "$corpus/"
cp examples/hello.b examples/tour.b "$corpus/"

mkdir -p build/fuzz-artifacts
if [[ "$(uname -s)" == Darwin ]]; then
    ./build/fuzz-frontend "$corpus" "$seconds"
else
    ./build/fuzz-frontend \
        "$corpus" \
        -artifact_prefix=build/fuzz-artifacts/ \
        -max_len=65536 \
        -timeout=10 \
        -seed="${FUZZ_SEED:-1}" \
        -max_total_time="$seconds"
fi

echo "ok lexer, parser, AST and checker fuzz smoke (${seconds}s)"
