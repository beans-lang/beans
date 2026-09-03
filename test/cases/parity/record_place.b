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
//
// Four roots reach the same store and each one is here, because they are
// four different addresses and only one of them is a plain stack slot: a
// local, a local a closure captured (whose slot holds a cell pointer, so
// indexing the slot writes the record over that pointer — a native-only
// segfault the interpreter never sees), an `inout` parameter aliasing the
// caller's storage, and a heap object. A fixed-array hop sits in the middle
// of the local-rooted and the class-rooted chains, because an array step is
// where the record walk and the element walk share code — and the class one
// carries an owned reference, which the element store's own path still
// refuses.
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

    // the receiver a struct method writes through: `self` is the local,
    // and the write has to reach the caller's storage and not a copy
    inout fn bump(step: int) {
        self.count += step
    }
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
    pub cells: [Cell; 2] = [Cell { v: 1 }, Cell { v: 2 }]
    pub slots: [Slot; 2] =
        [Slot { held: new Loud("row0"), count: 0 },
         Slot { held: new Loud("row1"), count: 0 }]

    // a class method writing its own storage at depth: the walk ends at the
    // object pointer, so `self` is never asked whether it is a var
    pub fn deepen(value: int) {
        self.frame.bounds.size.x = value
    }
}

// an inout parameter aliases the caller's slot rather than copying it, so
// every hop of the chain has to land back in the caller's frame
fn shift(inout frame: Frame, by: int) {
    frame.bounds.origin.x += by
    frame.bounds.size.y = by
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

    // a fixed-array element inside a heap object, and an owned reference
    // stored into a record inside that array: the write barrier the direct
    // class field store emits has to reach this address too
    holder.cells[1].v = 21
    holder.slots[0].count = 6
    holder.slots[1].held = new Loud("row1new")
    io.println("classarray {holder.cells[0].v} {holder.cells[1].v} {holder.slots[0].count} {holder.slots[1].held.tag_of()}")

    // a class method writing its own record at depth
    holder.deepen(13)
    io.println("method {holder.frame.bounds.size.x}")

    // through inout self of a struct method, and through an inout parameter
    var counter: Slot = Slot { held: new Loud("counter"), count: 0 }
    counter.count = 4
    counter.bump(3)
    io.println("inout {counter.count} {counter.held.tag_of()}")
    shift(inout frame, 5)
    io.println("param {frame.bounds.origin.x} {frame.bounds.size.y}")

    // a captured local: its slot holds a cell pointer, not the record, so a
    // store that indexed the slot itself would overwrite that pointer. The
    // closure reads the same storage the writes below land in.
    var shared: Frame =
        Frame {
            bounds: Rect {
                origin: Point { x: 0, y: 0 },
                size: Point { x: 0, y: 0 }
            },
            depth: 0
        }
    let peek: fn() -> int = fn() -> int {
        return shared.bounds.origin.x + shared.depth
    }
    shared.bounds.origin.x = 30
    shared.depth = 4
    io.println("captured {peek()} {shared.bounds.origin.x} {shared.depth}")
}
