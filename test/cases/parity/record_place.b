// A struct field is written through the storage the struct lives in, at any
// depth. Only the last hop used to be allowed, so `rect.origin.x = 1` was a
// copy-out, mutate, copy-back by hand.
//
// Two things have to hold and only one of them is visible in the answers.
// The write has to land in the original and not in a copy, which the printed
// values show. And a reference the write displaces has to be released exactly
// once, and the replacement retained exactly once — which only the markers
// show. The class-rooted case is the one that carries the cycle-collector
// publication barrier, so it is the one that owns Loud values.
package main

import std.io

class Loud {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    pub fn tag_of() -> string { return self.tag }
}

struct Point {
    x: int
    y: int
}

struct Rect {
    origin: Point
    size: Point
}

struct Frame {
    bounds: Rect
    depth: int
}

struct Slot {
    held: Loud
    count: int
}

struct Cell {
    v: int
}

struct Grid {
    cells: [Cell; 3]
    tag: int
}

class Holder {
    pub frame: Frame =
        Frame {
            bounds: Rect {
                origin: Point { x: 0, y: 0 },
                size: Point { x: 0, y: 0 }
            },
            depth: 0
        }
    pub slot: Slot = Slot { held: new Loud("initial"), count: 0 }
}

fn main() {
    // two hops on a local, then three
    var frame: Frame =
        Frame {
            bounds: Rect {
                origin: Point { x: 1, y: 2 },
                size: Point { x: 3, y: 4 }
            },
            depth: 5
        }
    frame.bounds.origin.x = 42
    frame.bounds.size.y += 6
    frame.depth = 9
    io.println("local {frame.bounds.origin.x} {frame.bounds.origin.y} {frame.bounds.size.x} {frame.bounds.size.y} {frame.depth}")

    // a copy is independent: the write above and below touch one struct each
    var copied: Frame = frame
    copied.bounds.origin.x = 7
    io.println("copy {frame.bounds.origin.x} {copied.bounds.origin.x}")

    // rooted at a heap object, through two struct hops
    let holder: Holder = new Holder()
    holder.frame.bounds.origin.y = 11
    holder.frame.depth = 12
    io.println("class {holder.frame.bounds.origin.y} {holder.frame.depth}")

    // an owned reference written into a record that lives inside a heap
    // object: the displaced value is released, the new one retained
    holder.slot.count = 3
    holder.slot.held = new Loud("replaced")
    io.println("slot {holder.slot.held.tag_of()} {holder.slot.count}")

    // rooted at a fixed-array element
    var grid: Grid =
        Grid {
            cells: [Cell { v: 1 }, Cell { v: 2 }, Cell { v: 3 }],
            tag: 0
        }
    grid.cells[1].v = 99
    grid.cells[2].v += 10
    io.println("array {grid.cells[0].v} {grid.cells[1].v} {grid.cells[2].v}")

    // through inout self of a struct method
    var counter: Slot = Slot { held: new Loud("counter"), count: 0 }
    counter.count = 4
    io.println("inout {counter.count} {counter.held.tag_of()}")
}
