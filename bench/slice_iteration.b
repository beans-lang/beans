// Focused benchmark for a temporary List slice consumed by one loop.
import std.io
import std.os
import std.time

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(1_000_000)
    let rounds: int = args.get(1).or("").to_int().or(50)
    var values: List<int> = []
    values.reserve(n)
    for index: int in 0..n { values.push(index & 255) }

    var checksum: int = 0
    let started: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        for value: int in values.slice(100, n - 100) {
            checksum += value
        }
    }
    let elapsed: int = time.monotonic_nanos() - started
    io.println("slice_iteration {elapsed} ns {checksum}")
}
