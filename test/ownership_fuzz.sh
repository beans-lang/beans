#!/usr/bin/env bash
# Ownership fuzzing: who is allowed to touch a value, and how many names it
# may have while they do. Two rules, both invisible at runtime when they are
# wrong — a Mutex that should not have crossed a thread, or a second live
# reader of a move-only map value — so the generator randomizes the shapes
# that decide each answer and an independent model in tools/ownership_fuzz.py
# decides them too. Accepted programs also have to run and count correctly on
# every lane; refused ones have to be refused for the stated reason.
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
