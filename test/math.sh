#!/usr/bin/env bash
# std.math's transcendentals against the platform's libm.
#
# The vectors in test/cases/math_vectors.b are raw 64-bit patterns captured
# from libm by tools/gen_math_vectors.py, which records how and why. Comparing
# patterns rather than printed digits matters: Beans prints ten significant
# digits, so a printed comparison would agree to ten and say nothing about the
# other seven.
#
# The tolerance is in representable steps, not a relative epsilon, because the
# interesting inputs are the multiples of pi/2 where the answer is near zero
# and a relative test passes on values that are wrong by most of themselves.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-math.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# 2 steps is the shipped bound. It is not a placeholder: exp measures 1 and
# sin/cos 2 over 22,924 points, so a regression of one more step fails here.
limit=2

./build/beansc run test/cases/math_vectors.b >"$tmp/interp"
./build/beansc build test/cases/math_vectors.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

checked=$(sed -n 's/^checked //p' "$tmp/interp")
if [ "${checked:-0}" -lt 600 ]; then
    echo "only $checked vectors ran — the table did not load" >&2
    exit 1
fi
for name in exp sin cos; do
    gap=$(sed -n "s/^$name //p" "$tmp/interp")
    if [ -z "$gap" ]; then
        echo "$name reported no result" >&2
        exit 1
    fi
    if [ "$gap" -gt "$limit" ]; then
        echo "$name is $gap steps from libm, over the $limit-step bound" >&2
        exit 1
    fi
done
echo "  ok transcendentals: $checked vectors, within $limit steps of libm"

# The elementary helpers have exact answers, so they are checked by value.
./build/beansc run test/cases/math_basics.b >"$tmp/basics.interp"
./build/beansc build test/cases/math_basics.b -o "$tmp/basics" \
    >"$tmp/basics.build" 2>&1
"$tmp/basics" >"$tmp/basics.native"
diff -u test/cases/math_basics.out "$tmp/basics.interp"
diff -u test/cases/math_basics.out "$tmp/basics.native"

echo "ok std.math: transcendentals within $limit steps of libm, helpers exact"
