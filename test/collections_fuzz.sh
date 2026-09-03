#!/usr/bin/env bash
# Differential fuzzing for std.collections. The generator in
# tools/collections_fuzz.py drives Set, Deque, PriorityQueue and SortedMap
# through random operation streams and checks every answer against a plain
# Python model, on the interpreter and every native lane. A lost rotation, a
# non-FIFO tie-break or a mispruned range scan is a wrong answer, so it needs a
# search rather than a fixed case.
#
#   test/collections_fuzz.sh smoke   # a small pinned run, both interpreters
#   test/collections_fuzz.sh run     # a larger session with native lanes
#   test/collections_fuzz.sh long    # the soak
#
# Replay one case:
#   python3 tools/collections_fuzz.py --start SEED_CASE --cases 1 --lanes ...
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-smoke}"

case "$mode" in
    smoke)
        cases="${COLLECTIONS_FUZZ_CASES:-8}"
        lanes="${COLLECTIONS_FUZZ_LANES:-interp,debug}"
        ;;
    run)
        cases="${COLLECTIONS_FUZZ_CASES:-60}"
        lanes="${COLLECTIONS_FUZZ_LANES:-interp,debug,release}"
        ;;
    long)
        cases="${COLLECTIONS_FUZZ_CASES:-300}"
        lanes="${COLLECTIONS_FUZZ_LANES:-interp,debug,release,lto}"
        ;;
    *)
        echo "usage: test/collections_fuzz.sh [smoke|run|long]" >&2
        exit 2
        ;;
esac

command -v python3 >/dev/null 2>&1 || {
    echo "collections_fuzz: python3 is required" >&2
    exit 2
}
test -x build/beansc || {
    echo "collections_fuzz: build/beansc not built" >&2
    exit 1
}

python3 tools/collections_fuzz.py \
    --compiler build/beansc \
    --seed "${COLLECTIONS_FUZZ_SEED:-7}" \
    --start "${COLLECTIONS_FUZZ_START:-0}" \
    --cases "$cases" \
    --lanes "$lanes" \
    --jobs "${COLLECTIONS_FUZZ_JOBS:-2}" \
    --timeout "${COLLECTIONS_FUZZ_TIMEOUT:-90}"
