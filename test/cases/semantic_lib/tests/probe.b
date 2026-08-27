// A program of its own under `tests/`, the way a library's suites are written.

package main

import std.io
import semlib.deep

fn main() {
    let counter: deep.Counter = new deep.Counter(1)
    io.println("{counter.bump()} {deep.doubled(2)}")
}
