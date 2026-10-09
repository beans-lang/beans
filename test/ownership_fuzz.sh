#!/usr/bin/env bash
# Fuzz ownership rules against an independent model; accepted cases must run correctly on every lane and rejected cases must report the expected reason.
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-smoke}"

case "$mode" in
    smoke)
        cases="${OWNERSHIP_FUZZ_CASES:-12}"
        lanes="${OWNERSHIP_FUZZ_LANES:-interp,debug}"
        ;;
    run)
        cases="${OWNERSHIP_FUZZ_CASES:-80}"
        lanes="${OWNERSHIP_FUZZ_LANES:-interp,debug,release}"
        ;;
    long)
        cases="${OWNERSHIP_FUZZ_CASES:-400}"
        lanes="${OWNERSHIP_FUZZ_LANES:-interp,debug,release,lto}"
        ;;
    *)
        echo "usage: test/ownership_fuzz.sh [smoke|run|long]" >&2
        exit 2
        ;;
esac

test -x build/beansc || {
    echo "ownership_fuzz: build/beansc not built" >&2
    exit 1
}

python3 tools/ownership_fuzz.py \
    --compiler build/beansc \
    --seed "${OWNERSHIP_FUZZ_SEED:-7}" \
    --start "${OWNERSHIP_FUZZ_START:-0}" \
    --cases "$cases" \
    --lanes "$lanes" \
    --jobs "${OWNERSHIP_FUZZ_JOBS:-2}" \
    --timeout "${OWNERSHIP_FUZZ_TIMEOUT:-90}"
