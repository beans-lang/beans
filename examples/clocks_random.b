// Use the monotonic clock for durations and wall time for timestamps.
// Secure random APIs use the OS CSPRNG, return `Result`, and have no weak fallback.
// The example prints derived facts so its output remains deterministic.

import std.io
import std.time
import std.random

fn main() {
    // Measuring a duration: read the monotonic clock twice and subtract.
    let started: int = time.monotonic_nanos()
    time.sleep_nanos(3000000) // 3ms
    let elapsed: int = time.monotonic_nanos() - started

    io.println("monotonic moved forward {elapsed > 0}")
    // sleep_nanos retries interrupted sleeps and waits at least the requested duration.
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

    // Rejection sampling avoids the modulo bias of `% limit`.
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
