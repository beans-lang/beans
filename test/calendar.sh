#!/usr/bin/env bash
# std.calendar: civil UTC dates, epoch conversion, and the two wire formats
# HTTP and logging need. Two checks. First a golden behavioural case pins the
# HTTP date forms, RFC 3339 offsets and fractions, calendar arithmetic and
# every error path, byte for byte on both backends and under ASan. Then a
# differential run generates thousands of epoch instants across the whole
# proleptic-Gregorian range — negative epochs, leap days, non-leap centuries,
# both calendar ends — and checks Beans against Python's datetime, which shares
# calendar.b's three decisions (proleptic Gregorian, years 1..9999, no leap
# seconds). A single wrong day or format byte fails the diff.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-calendar.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

command -v python3 >/dev/null 2>&1 || {
    echo "calendar: python3 is required for the datetime differential" >&2
    exit 2
}

echo "checking the calendar golden on both backends and under ASan"
./build/beansc run test/cases/calendar_basics.b >"$tmp/interp"
./build/beansc build test/cases/calendar_basics.b -o "$tmp/native" >"$tmp/build"
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/calendar_basics.out "$tmp/interp"
diff -u "$tmp/interp" "$tmp/native.out"

clang -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wno-override-module build/calendar_basics.ll build/beans_rt.c -lm -o "$tmp/asan"
# The calendar allocates and frees a string for every field it formats and
# parses, so LeakSanitizer (default on Linux) covers those loops. A non-zero
# exit is a failure; the grep names any of the three sanitizers so a leak is
# loud rather than a silent death under `set -e`.
if ! BEANS_NO_POOL=1 "$tmp/asan" >"$tmp/asan.out" 2>"$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    echo "calendar_basics exited non-zero under the sanitizers" >&2
    exit 1
fi
if grep -Eq 'AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer' \
    "$tmp/asan.err"; then
    cat "$tmp/asan.err" >&2
    exit 1
fi
diff -u "$tmp/interp" "$tmp/asan.out"

count="${CALENDAR_VECTORS:-3000}"
seed="${CALENDAR_SEED:-1}"
echo "checking $count calendar vectors against Python's datetime (seed $seed)"
python3 tools/calendar_vectors.py --count "$count" --seed "$seed" \
    --program "$tmp/vectors.b" --expected "$tmp/expected.txt"

./build/beansc run "$tmp/vectors.b" >"$tmp/vectors.interp"
diff -u "$tmp/expected.txt" "$tmp/vectors.interp"

./build/beansc build "$tmp/vectors.b" -o "$tmp/vectors.native" >"$tmp/vectors.build"
"$tmp/vectors.native" >"$tmp/vectors.native.out"
diff -u "$tmp/expected.txt" "$tmp/vectors.native.out"

echo "ok std.calendar golden, ASan, and $count datetime vectors"
