#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-clocks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking clocks and secure random in both backends"
./build/beansc run examples/clocks_random.b >"$tmp/interp"
./build/beansc build examples/clocks_random.b -o "$tmp/native" >"$tmp/build.log" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u "$tmp/interp" "$tmp/native.out"

# Every line is a derived fact, so the expected output is exact even though the
# values differ on every run and every machine.
diff -u - "$tmp/interp" <<'EXPECTED'
monotonic moved forward true
slept at least 3ms true
never goes backwards true
wall clock is a real date true
got 32 random bytes
a die roll is in range true
two draws differ true
bad bound rejected: invalid
negative count rejected: invalid
EXPECTED

echo "checking the monotonic clock is not the wall clock"
# Two separate clocks, and the difference is observable: the wall clock is
# nanoseconds since 1970 and so is a huge number, while the monotonic clock counts
# from an unspecified start and on both supported platforms is far smaller. A build
# that wired one to the other would show up here.
cat >"$tmp/clocks.b" <<'CLOCKS'
import std.io
import std.time
fn main() {
    let mono: int = time.monotonic_nanos()
    let wall: int = time.wall_nanos()
    io.println("wall is far larger {wall > mono * 2}")
    // Monotonic differences are the only thing monotonic readings mean, and they
    // must be non-negative over any number of reads.
    var last: int = time.monotonic_nanos()
    var backwards: int = 0
    var i: int = 0
    for i < 2000 {
        let now: int = time.monotonic_nanos()
        if now < last { backwards += 1 }
        last = now
        i += 1
    }
    io.println("never went backwards over 2000 reads {backwards == 0}")
}
CLOCKS
./build/beansc run "$tmp/clocks.b" >"$tmp/clocks.interp"
./build/beansc build "$tmp/clocks.b" -o "$tmp/clocks" >/dev/null 2>&1
"$tmp/clocks" >"$tmp/clocks.native"
diff -u "$tmp/clocks.interp" "$tmp/clocks.native"
grep -q '^wall is far larger true$' "$tmp/clocks.interp"
grep -q '^never went backwards over 2000 reads true$' "$tmp/clocks.interp"

echo "checking sleep_nanos is a floor, not an estimate"
# A signal must not shorten it. Measured with the monotonic clock, which is what it
# is for.
cat >"$tmp/sleep.b" <<'SLEEP'
import std.io
import std.time
fn main() {
    var short_sleeps: int = 0
    var i: int = 0
    for i < 20 {
        let before: int = time.monotonic_nanos()
        time.sleep_nanos(1000000)
        if time.monotonic_nanos() - before < 1000000 { short_sleeps += 1 }
        i += 1
    }
    io.println("no sleep came back early {short_sleeps == 0}")
}
SLEEP
./build/beansc run "$tmp/sleep.b" >"$tmp/sleep.interp"
./build/beansc build "$tmp/sleep.b" -o "$tmp/sleep" >/dev/null 2>&1
"$tmp/sleep" >"$tmp/sleep.native"
diff -u "$tmp/sleep.interp" "$tmp/sleep.native"
grep -q '^no sleep came back early true$' "$tmp/sleep.interp"

echo "checking the millisecond clocks live in std.time and match the nanosecond ones"
# The millisecond clocks moved out of std.os, where their names said nothing about
# which clock they read. Same two clocks as the nanosecond forms, coarser, and
# std.os must no longer answer to the old spellings in either compiler.
cat >"$tmp/millis.b" <<'MILLIS'
import std.io
import std.time
fn main() {
    let wall_ms: int = time.wall_millis()
    let wall_ns: int = time.wall_nanos()
    io.println("wall_millis agrees with wall_nanos {(wall_ns / 1000000) - wall_ms < 1000}")
    io.println("wall_millis is a real date {wall_ms > 1600000000000}")
    let before: int = time.monotonic_millis()
    time.sleep_millis(5)
    let waited: int = time.monotonic_millis() - before
    io.println("sleep_millis waited {waited >= 4}")
    io.println("monotonic_millis is not the wall clock {wall_ms > before * 2}")
    var backwards: int = 0
    var last: int = time.monotonic_millis()
    var i: int = 0
    for i < 2000 {
        let now: int = time.monotonic_millis()
        if now < last { backwards += 1 }
        last = now
        i += 1
    }
    io.println("monotonic_millis never goes backwards {backwards == 0}")
}
MILLIS
./build/beansc run "$tmp/millis.b" >"$tmp/millis.interp"
./build/beansc0 run "$tmp/millis.b" >"$tmp/millis.stage0"
./build/beansc build "$tmp/millis.b" -o "$tmp/millis" >/dev/null 2>&1
"$tmp/millis" >"$tmp/millis.native"
diff -u "$tmp/millis.interp" "$tmp/millis.native"
diff -u "$tmp/millis.interp" "$tmp/millis.stage0"
diff -u - "$tmp/millis.interp" <<'EXPECTED'
wall_millis agrees with wall_nanos true
wall_millis is a real date true
sleep_millis waited true
monotonic_millis is not the wall clock true
monotonic_millis never goes backwards true
EXPECTED

# The std.os spellings are gone, and both compilers say so in the same words.
cat >"$tmp/old_clock.b" <<'OLD'
import std.io
import std.os
fn main() {
    let stamp: int = os.now_ms()
    io.println(stamp)
}
OLD
set +e
./build/beansc0 check "$tmp/old_clock.b" >"$tmp/old0" 2>&1; r0=$?
./build/beansc  check "$tmp/old_clock.b" >"$tmp/old1" 2>&1; r1=$?
set -e
if [[ "$r0" -eq 0 || "$r1" -eq 0 ]]; then
    echo "std.os still answers to now_ms (stage0=$r0 selfhost=$r1)" >&2
    exit 1
fi
diff -u "$tmp/old0" "$tmp/old1"
grep -q "has no function 'now_ms'" "$tmp/old0"

echo "checking random output is actually random"
# Not a statistical test — a shape test. A generator stuck at a constant, or one
# seeded identically each run, is the failure worth catching, and both show up as
# repeats across separate processes.
cat >"$tmp/draw.b" <<'DRAW'
import std.io
import std.random
fn main() {
    match random.u64() {
        ok(v) => io.println("{v}"),
        err(e) => io.println("failed {e.msg}"),
    }
}
DRAW
./build/beansc build "$tmp/draw.b" -o "$tmp/draw" >/dev/null 2>&1
for run in 1 2 3 4 5 6 7 8; do "$tmp/draw"; done >"$tmp/draws"
distinct=$(sort -u "$tmp/draws" | wc -l | tr -d ' ')
if [[ "$distinct" -ne 8 ]]; then
    echo "eight separate processes produced only $distinct distinct values" >&2
    cat "$tmp/draws" >&2
    exit 1
fi
# The interpreter draws from the same source, so it must not repeat either.
for run in 1 2 3 4; do ./build/beansc run "$tmp/draw.b"; done >"$tmp/idraws"
idistinct=$(sort -u "$tmp/idraws" | wc -l | tr -d ' ')
if [[ "$idistinct" -ne 4 ]]; then
    echo "the interpreter produced only $idistinct distinct values in 4 runs" >&2
    exit 1
fi

echo "checking a bounded draw covers its range without bias"
# 4000 draws below 4. Every bucket must appear, and none may dominate — a `% limit`
# implementation would still pass a coverage test, so the balance is checked too.
cat >"$tmp/spread.b" <<'SPREAD'
import std.io
import std.random
fn main() {
    var zero: int = 0
    var one: int = 0
    var two: int = 0
    var three: int = 0
    var failures: int = 0
    var i: int = 0
    for i < 4000 {
        match random.below(4) {
            ok(n) => {
                if n == 0 { zero += 1 }
                if n == 1 { one += 1 }
                if n == 2 { two += 1 }
                if n == 3 { three += 1 }
            }
            err(e) => { failures += 1 }
        }
        i += 1
    }
    var lowest: int = zero
    if one < lowest { lowest = one }
    if two < lowest { lowest = two }
    if three < lowest { lowest = three }
    var highest: int = zero
    if one > highest { highest = one }
    if two > highest { highest = two }
    if three > highest { highest = three }
    io.println("no failures {failures == 0}")
    io.println("every bucket used {lowest > 0}")
    // With 1000 expected per bucket, a fair generator stays well inside this. A
    // constant or a badly biased one does not.
    io.println("roughly balanced {highest < lowest * 2}")
}
SPREAD
./build/beansc run "$tmp/spread.b" >"$tmp/spread.interp"
./build/beansc build "$tmp/spread.b" -o "$tmp/spread" >/dev/null 2>&1
"$tmp/spread" >"$tmp/spread.native"
grep -q '^no failures true$' "$tmp/spread.interp"
grep -q '^every bucket used true$' "$tmp/spread.interp"
grep -q '^roughly balanced true$' "$tmp/spread.interp"
grep -q '^no failures true$' "$tmp/spread.native"
grep -q '^every bucket used true$' "$tmp/spread.native"
grep -q '^roughly balanced true$' "$tmp/spread.native"

echo "checking there is no pseudo-random fallback"
# The point of the design: nothing in the source may reach for rand(), random() or a
# seeded generator, because a caller asking for random bytes is usually making a key.
if grep -nE '\b(srand|rand48|mt19937|random\(\))' runtime/beans_rt.c compiler/bootstrap/builtins.cpp; then
    echo "a pseudo-random source appeared in the random path" >&2
    exit 1
fi
# And the real source is what is actually called.
if [[ "$(uname -s)" == Darwin ]]; then
    grep -q 'arc4random_buf' runtime/beans_rt.c
else
    grep -q 'SYS_getrandom' runtime/beans_rt.c
fi

echo "ok clocks measure durations, and random comes only from the OS"
