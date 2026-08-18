#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-smoke}"

case "$mode" in
    smoke)
        cases="${OOP_FUZZ_CASES:-16}"
        lanes="${OOP_FUZZ_LANES:-interp,debug}"
        ;;
    run)
        cases="${OOP_FUZZ_CASES:-100}"
        lanes="${OOP_FUZZ_LANES:-interp,debug,release,lto}"
        ;;
    long)
        cases="${OOP_FUZZ_CASES:-1000}"
        lanes="${OOP_FUZZ_LANES:-interp,debug,release,lto}"
        ;;
    *)
        echo "usage: test/oop_fuzz.sh [smoke|run|long]" >&2
        exit 2
        ;;
esac

test -x build/beansc || {
    echo "oop_fuzz: build/beansc not built" >&2
    exit 1
}

python3 tools/oop_fuzz.py \
    --compiler build/beansc \
    --seed "${OOP_FUZZ_SEED:-17}" \
    --start "${OOP_FUZZ_START:-0}" \
    --cases "$cases" \
    --lanes "$lanes" \
    --jobs "${OOP_FUZZ_JOBS:-2}" \
    --timeout "${OOP_FUZZ_TIMEOUT:-60}"
