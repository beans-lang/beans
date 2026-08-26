#!/usr/bin/env bash
# `x as? T` normally retains what the Option wraps. When MIR can prove the
# source outlives the match, that retain and its release cancel. The cases pin
# both directions: the safe shapes really stopped retaining, and every shape
# that can outlive its source kept its count.
#
# The negatives carry as much weight as the positives here. Eliding one of them
# is a leak or a use-after-free, and neither shows up in the printed answer —
# which is why this file greps the MIR as well as diffing the output.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-downcast-borrow.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/downcast_borrow.b >"$tmp/interp"
./build/beansc build test/cases/downcast_borrow.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/downcast_borrow.out "$tmp/interp"
diff -u test/cases/downcast_borrow.out "$tmp/native.out"

mir_body() {
    ./build/beansc mir test/cases/downcast_borrow.b |
        awk -v name="main::$1" '
            $1 == "fn" && $2 == name { inside = 1; next }
            $1 == "fn" { inside = 0 }
            inside'
}

elides() {
    local name=$1
    local want=$2
    local body
    body=$(mir_body "$name")
    local seen
    seen=$(printf '%s\n' "$body" | grep -c 'cast as?.*borrow-elided' || true)
    if [ "$seen" != "$want" ]; then
        echo "$name: expected $want elided downcasts, found $seen" >&2
        printf '%s\n' "$body" | grep 'cast as?' >&2 || true
        exit 1
    fi
}

# the source is a local that never changes, escapes or is captured
elides reads 1
elides nested 2

# a borrowed parameter's slot belongs to the caller: nothing here can prove
# what the caller does with it for the duration of the call
elides parameter 0
# the source is reassigned while the binding is live
elides reassigned 0
# the binding outlives the arm inside a closure
elides captured 0
# the Option lands in a local, so its uses are not just this match
elides to_local 0

# an elided bind must not retain either: the retain and the drop are a pair,
# and keeping one without the other leaks instead of saving
if mir_body reads | grep -q 'drop_local dot'; then
    echo "reads: the elided binding still drops" >&2
    exit 1
fi
if mir_body reads | grep -q 'pattern_bind dot.*releases'; then
    echo "reads: the elided binding still schedules a release" >&2
    exit 1
fi
./build/beansc llvm test/cases/downcast_borrow.b >"$tmp/ir" 2>/dev/null
# the kept shapes still emit their retain, so the count cannot reach zero
if ! grep -q 'call void @beans_retain' "$tmp/ir"; then
    echo "no retains at all — the negatives stopped retaining too" >&2
    exit 1
fi

echo "ok downcast borrow: elided where the source outlives the match, kept elsewhere"
