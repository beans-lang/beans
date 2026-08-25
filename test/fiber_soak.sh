#!/usr/bin/env bash
# The panic-storm soak (spec/CONCURRENCY.md, F3): panic containment is a
# per-fiber guarantee, so it is proven at storm scale — ~2600 fibers and
# ~900 contained panics across TaskGroup fleets, lone joined handles, a
# gate storm, senders panicking on a closed channel, and four threads
# running fleets of their own. Every failure arrives as a value, the
# programs stand, and both engines print identical bytes.
set -euo pipefail

# macOS runners ship no GNU timeout; stand in for it when absent. The
# stand-in reports 137 (SIGKILL) where GNU prints 124 — every use here
# only cares that a hang cannot pass, and neither code ever matches an
# expected exit.
if ! command -v timeout >/dev/null 2>&1; then
timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local dog=$!
    local status=0
    wait "$pid" || status=$?
    kill "$dog" 2>/dev/null
    wait "$dog" 2>/dev/null || true
    return "$status"
}
fi

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-fiber-soak.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the single-worker panic storm stays contained and identical"
timeout 180 ./build/beansc run test/cases/fiber_soak.b >"$tmp/interp"
./build/beansc build test/cases/fiber_soak.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
timeout 60 "$tmp/native" >"$tmp/native.out"
diff -u test/cases/fiber_soak.out "$tmp/interp"
diff -u test/cases/fiber_soak.out "$tmp/native.out"

echo "checking the storm across four workers"
timeout 180 ./build/beansc run test/cases/fiber_soak_threads.b \
    >"$tmp/interp2"
./build/beansc build test/cases/fiber_soak_threads.b -o "$tmp/native2" \
    >"$tmp/build2" 2>&1
timeout 60 "$tmp/native2" >"$tmp/native2.out"
diff -u test/cases/fiber_soak_threads.out "$tmp/interp2"
diff -u test/cases/fiber_soak_threads.out "$tmp/native2.out"

echo "ok fiber soak: contained panic storms, both engines identical"
