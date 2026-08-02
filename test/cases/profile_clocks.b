// Clocks are a hosted service: fine under minimal, gone under freestanding.
import std.io
import std.time
fn main() {
    io.println("the clock moves forward {time.monotonic_nanos() > 0}")
}
