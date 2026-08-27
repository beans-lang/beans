#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-send-handles.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/send_handles.b >"$tmp/interp"
./build/beansc build test/cases/send_handles.b \
    -o "$tmp/native" >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/send_handles.out "$tmp/interp"
diff -u test/cases/send_handles.out "$tmp/native.out"

echo "ok cross-thread move and destruction for Send standard-library handles"

# A Mutex owns what it locks. For a move-only value that is the whole story —
# the constructor consumes it and with_lock hands out a borrow nothing may
# store — so the Mutex is Send and Sync without the class promising anything.
# The counters are exact because the lock serializes; a hole in the rule shows
# up as a wrong total, not as a flake.
./build/beansc run test/cases/mutex_confined.b >"$tmp/mutex.interp"
./build/beansc build test/cases/mutex_confined.b \
    -o "$tmp/mutex.native" >"$tmp/mutex.build" 2>&1
"$tmp/mutex.native" >"$tmp/mutex.native.out"
diff -u test/cases/mutex_confined.out "$tmp/mutex.interp"
diff -u test/cases/mutex_confined.out "$tmp/mutex.native.out"

if ./build/beansc check test/cases/mutex_confined_bad.b \
    >"$tmp/mutex-bad" 2>&1; then
    echo "mutex_confined_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -q "Declare 'main.Plain' a unique class" "$tmp/mutex-bad"
grep -q "'main.Leaky.inner' of type main.Aliasable is reachable without the lock" \
    "$tmp/mutex-bad"
# the field that fails is two hops in, and the message names it, not the top
grep -q "'main.Deep.nested.inner' of type main.Aliasable" "$tmp/mutex-bad"

echo "ok a Mutex is Send when it owns what it locks, and says why when it does not"
