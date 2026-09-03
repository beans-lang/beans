// A static field is the third storage root a place chain can end at, beside
// a local's slot and the heap object a class field sits in. It was refused
// until now, so `Cfg.home.origin.x = 1` meant reading the whole static into
// a var, updating it, and assigning the whole thing back.
//
// It is not the same root as the other two and the difference is not
// spelling. A static has no owning object whose bit gates a write and no
// scope that orders it, so a reference stored beneath one takes the cycle
// collector's *static* form — the barrier a whole-static store already
// emits. That is the half the printed values cannot see, so the reference
// here is held through an Option and finally cleared: nothing tears a static
// down at exit (issue #74), so a value left in one at the end would be an
// unbalanced marker for a reason this case is not about.
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

struct Slot {
    held: Option<Loud>
    count: int
}

class Cfg {
    static home: Rect =
        Rect {
            origin: Point { x: 1, y: 2 },
            size: Point { x: 3, y: 4 }
        }
    static cells: [int; 3] = [1, 2, 3]
    static grid: [Point; 2] =
        [Point { x: 0, y: 0 }, Point { x: 0, y: 0 }]
    static slot: Slot = Slot { held: none, count: 0 }
}

fn held_name(slot: Slot) -> string {
    match slot.held {
        some(loud) => { return loud.tag_of() }
        none => { return "empty" }
    }
}

fn main() {
    // two hops into a static, and a compound form
    Cfg.home.origin.x = 42
    Cfg.home.size.y += 6
    io.println("home {Cfg.home.origin.x} {Cfg.home.origin.y} {Cfg.home.size.x} {Cfg.home.size.y}")

    // a fixed-array element of a static, plain and compound
    Cfg.cells[1] = 9
    Cfg.cells[2] += 10
    io.println("cells {Cfg.cells[0]} {Cfg.cells[1]} {Cfg.cells[2]}")

    // a struct field through a static's array element: the record walk and
    // the element walk meet on the same root
    Cfg.grid[1].x = 7
    Cfg.grid[0].y += 3
    io.println("grid {Cfg.grid[0].x} {Cfg.grid[0].y} {Cfg.grid[1].x}")

    // a copy read out of a static is a copy: writing it leaves the static
    // where it was
    var snapshot: Rect = Cfg.home
    snapshot.origin.x = 500
    io.println("copy {Cfg.home.origin.x} {snapshot.origin.x}")

    // an owned reference written into a record inside a static: the store
    // takes the collector's static barrier, and each write releases what the
    // static held before
    Cfg.slot.count = 1
    Cfg.slot.held = some(new Loud("first"))
    io.println("slot {held_name(Cfg.slot)} {Cfg.slot.count}")
    Cfg.slot.held = some(new Loud("second"))
    Cfg.slot.count += 1
    io.println("slot {held_name(Cfg.slot)} {Cfg.slot.count}")
    Cfg.slot.held = none
    io.println("slot {held_name(Cfg.slot)} {Cfg.slot.count}")
}
