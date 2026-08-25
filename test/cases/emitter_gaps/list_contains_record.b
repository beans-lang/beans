// gap: LLVM emitter does not support wide list elements in List.contains yet
//
// Same family as the sort fix in this tree: an element wider than one slot.
// Sorting was reachable because a comparator arrives with the call; contains
// needs structural equality for the element type, which the emitter has for
// scalars, strings, enums and references but not for an inline record.
//
// Workaround today: compare fields in a loop.
package main

import std.io

struct Point {
    x: int
    y: int
}

fn main() {
    var points: List<Point> = [Point { x: 1, y: 2 }]
    io.println("{points.contains(Point { x: 1, y: 2 })}")
}
