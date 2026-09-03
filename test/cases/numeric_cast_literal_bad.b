// A hex literal in a real-number type has to be an int value: there is no
// bit-pattern rule to fall back on the way u64 has one. The checker used to
// take this and then the two backends went different ways.
import std.io

fn main() {
    let f: float = 0xFFFFFFFFFFFFFFFF
    io.println("{f}")
}
