// Clocks and secure random.
//
// Two clocks, with separate names because picking the wrong one is a real bug:
//
//   `time.monotonic_nanos()` never goes backwards and is unaffected by anyone
//   setting the date. It has no meaning as a moment — only differences between
//   readings mean anything — and it is the only correct way to measure a duration.
//
//   `time.wall_nanos()` names a moment: nanoseconds since 1970. It can jump forwards
//   or backwards when the clock is adjusted, so measuring elapsed time with it is
//   the bug the two names exist to prevent.
//
// `std.random` is the OS CSPRNG and nothing else. There is deliberately no fallback
// to a pseudo-random generator, because a caller asking for random bytes is usually
// making a key, a token or a nonce — and quietly handing over a predictable sequence
// is worse than failing. Every entry point returns a Result.
//
// Everything here prints a *derived fact* rather than a value, because the values
// differ every run and on every machine. The facts do not.

import std.io
import std.time
import std.random

fn main() {
    // Measuring a duration: read the monotonic clock twice and subtract.
    let started: int = time.monotonic_nanos()
    time.sleep_nanos(3000000) // 3ms
    let elapsed: int = time.monotonic_nanos() - started

    io.println("monotonic moved forward {elapsed > 0}")
    // sleep_nanos sleeps *at least* as long as asked, retrying if a signal cuts it
    // short — so this is a floor, not an approximation.
    io.println("slept at least 3ms {elapsed >= 3000000}")
    // Two readings in a row can be equal on a coarse clock but never decreasing.
    io.println("never goes backwards {time.monotonic_nanos() >= started}")

    // The wall clock names a moment, so it is well past 2020 and not a small number.
    io.println("wall clock is a real date {time.wall_nanos() > 1600000000000000000}")

    // Secure random. Asking for bytes gives exactly that many.
    match random.bytes(32) {
        ok(key) => io.println("got {key.len()} random bytes"),
        err(e) => io.println("no random source: {e.msg}"),
    }

    // A bounded draw is uniform by rejection sampling, not by `% limit` — modulo is
    // biased unless the limit divides 2^64, and for a shuffle or a token that bias is
    // the whole problem.
    match random.below(6) {
        ok(roll) => io.println("a die roll is in range {roll >= 0 && roll < 6}"),
        err(e) => io.println("no random source: {e.msg}"),
    }

    // Two draws of 64 bits are essentially never equal. This is the weakest useful
    // check that something is actually random rather than a constant.
    match random.u64() {
        ok(first) => {
            match random.u64() {
                ok(second) => io.println("two draws differ {first != second}"),
                err(e) => io.println("no random source: {e.msg}"),
            }
        }
        err(e) => io.println("no random source: {e.msg}")
    }

    // Invalid input is a Result, not a panic: these are ordinary failures.
    match random.below(0) {
        ok(n) => io.println("unexpected {n}"),
        err(e) => io.println("bad bound rejected: {e.kind}"),
    }
    match random.bytes(-1) {
        ok(b) => io.println("unexpected {b.len()}"),
        err(e) => io.println("negative count rejected: {e.kind}"),
    }
}
