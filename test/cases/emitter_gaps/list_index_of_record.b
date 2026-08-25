// gap: LLVM emitter does not support List<main.Point>.index_of yet
//
// The other half of the same missing piece as list_contains_record: an
// inline record has no structural equality in the emitter, so the runtime
// has no comparator kind to scan with.
package main

import std.io

struct Point {
    x: int
    y: int
}

fn main() {
    var points: List<Point> = [Point { x: 1, y: 2 }]
    match points.index_of(Point { x: 1, y: 2 }) {
        some(at) => { io.println("found {at}") }
        none => { io.println("missing") }
    }
}
