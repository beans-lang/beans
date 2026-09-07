#!/usr/bin/env bash
# A list is a header and an element buffer, and this is what the pair costs.
#
# A buffer small enough to fit is carved out of the header's own block, so
# `data` points inside the object. Three things have to hold for that, and each
# one is a way to corrupt the heap if it does not:
#
#   1. freeing the list must not hand that interior pointer to free/munmap;
#   2. growing it must place a real buffer and copy, never realloc the interior
#      pointer;
#   3. a buffer too big to fit must still get a block of its own.
#
# (1) and (2) are checked by behaviour and by the sanitizers; (3) is checked by
# counting, because a runtime that inlined every buffer at any size would pass
# every behavioural test here and blow the pool's size classes.
#
# The counting lane runs each shape at two round counts and reads the
# difference, so what the process allocates on the way to main cancels out.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-list-backing.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking list operations either side of the inline backing threshold"
./build/beansc run test/cases/list_inline_backing.b >"$tmp/interp"
./build/beansc build test/cases/list_inline_backing.b -o "$tmp/native" >"$tmp/build"
"$tmp/native" >"$tmp/native.out"
# Golden byte for byte on both backends, and the two backends against each other.
diff -u test/cases/list_inline_backing.out "$tmp/interp"
diff -u "$tmp/interp" "$tmp/native.out"
# The golden prints the struct widths it is testing with. If a layout change
# moved one of them across the threshold the golden would have to change, and
# these lines say which side each case is on rather than leaving it implied.
grep -q '^sizes pair=16 quad=32 five=40 slab=160$' "$tmp/interp"

echo "counting the blocks a list costs"
./build/beansc build test/cases/list_inline_counts.b -o "$tmp/counts" >"$tmp/counts.build"
clang -O1 -pthread -DBEANS_ARC_STATS -Wno-override-module \
    build/list_inline_counts.ll build/beans_rt.c -lm -o "$tmp/counts.stats"

# mode  per-round element buffers allocated in a block of their own
#
#   small  three ints (32 bytes of backing) ride behind the header
#   grow   nine ints: capacity 4 -> 8 -> 16, so two buffers, and the first
#          four elements start inline — a runtime that never inlined would
#          report three here
#   wide   three 40-byte structs: 4 x 40 = 160 bytes is more than a block
#          carries, so the buffer is separate from the first push
#   six    a six-element literal: past the four a fresh list starts with,
#          so the literal has to ask for six — doubling its way there
#          would leave the inline room behind and cost a buffer
#   twenty a twenty-element literal: 160 bytes of slots is past the
#          threshold, so one buffer, where doubling from four costs four
#   slab   three 160-byte structs: one element is already wider than the
#          whole allowance, the other way the fit test says no
expect_backings() {
    local mode="$1" per_round="$2" low high
    low=$(MODE="$mode" ROUNDS=1000 "$tmp/counts.stats" 2>&1 >/dev/null \
          | tr ' ' '\n' | sed -n 's/^list_backings=//p')
    high=$(MODE="$mode" ROUNDS=2000 "$tmp/counts.stats" 2>&1 >/dev/null \
           | tr ' ' '\n' | sed -n 's/^list_backings=//p')
    if [ -z "$low" ] || [ -z "$high" ]; then
        echo "no arc stats from the $mode build" >&2
        exit 1
    fi
    local got=$(( (high - low) / 1000 ))
    if [ "$got" != "$per_round" ]; then
        echo "$mode: $got separate element buffers per round, expected $per_round" \
             "(1000 rounds: $low, 2000 rounds: $high)" >&2
        exit 1
    fi
    echo "  $mode: $per_round separate element buffer(s) per round"
}
expect_backings small  0
expect_backings grow   2
expect_backings wide   1
expect_backings six    0
expect_backings twenty 1
expect_backings slab   1

# A literal longer than the default four has to reach the capacity constructor;
# nothing else in the emitter would ask for an exact size.
grep -q 'call ptr @beans_list_new_typed_capacity' build/list_inline_counts.ll

# The header count must not have moved to pay for it: one list object per round
# in every mode, inline backing or not.
expect_headers() {
    local mode="$1" low high
    low=$(MODE="$mode" ROUNDS=1000 "$tmp/counts.stats" 2>&1 >/dev/null \
          | tr ' ' '\n' | sed -n 's/^allocations=//p')
    high=$(MODE="$mode" ROUNDS=2000 "$tmp/counts.stats" 2>&1 >/dev/null \
           | tr ' ' '\n' | sed -n 's/^allocations=//p')
    local got=$(( (high - low) / 1000 ))
    if [ "$got" != 1 ]; then
        echo "$mode: $got objects allocated per round, expected 1" >&2
        exit 1
    fi
}
expect_headers small
expect_headers grow
expect_headers wide
expect_headers six
expect_headers twenty
expect_headers slab

echo "checking the inline backing under ASan, UBSan and LeakSanitizer"
clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module build/list_inline_backing.ll build/beans_rt.c -lm \
    -o "$tmp/asan"
# Twice, because the two arms of beans_alloc place the block differently and
# only one of them is a plain malloc ASan can see the bounds of:
#
#   pool off  every object is its own malloc'd block, so freeing or
#             reallocating a pointer into the middle of one is a report rather
#             than a silently accepted slab address;
#   pool on   the shipped path, where the block is carved out of a 64 KB slab
#             and the check is that nothing walks off it.
#
# `env -u` and not BEANS_NO_POOL= for the second: the runtime reads that
# variable with getenv() != NULL, so setting it to the empty string turns the
# pool OFF and this would have run the first lane twice.
#
# This program drops everything it builds, so LeakSanitizer — on by default
# inside ASan on Linux, absent on macOS — must stay silent either way.
asan_lane() {
    local label="$1"
    shift
    local status=0
    "$@" >"$tmp/asan.out" 2>"$tmp/asan.err" || status=$?
    if [ "$status" != 0 ]; then
        cat "$tmp/asan.err" >&2
        echo "list_inline_backing exited $status under the sanitizers ($label)" >&2
        exit 1
    fi
    if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
        "$tmp/asan.err"; then
        cat "$tmp/asan.err" >&2
        echo "sanitizer report from list_inline_backing ($label)" >&2
        exit 1
    fi
    diff -u test/cases/list_inline_backing.out "$tmp/asan.out"
    echo "  clean with the pool $label"
}
asan_lane off env BEANS_NO_POOL=1 "$tmp/asan"
asan_lane on  env -u BEANS_NO_POOL "$tmp/asan"

echo "list backing checks passed"
