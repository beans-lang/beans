// A struct field is a place at any depth, and the walk back to the storage
// ends in exactly one of a handful of ways. Every refusal names which one it
// hit, because "needs a local variable" was never the reason and sent people
// looking for the wrong fix. Each branch of that walk is here, so a rule
// that quietly loosens fails this file rather than passing it.
import std.io

struct Pt {
    x: int
    y: int
}

struct Rect {
    origin: Pt
}

extern "C" struct CPt {
    x: i32
    y: i32
}

extern "C" union Bits {
    whole: i64
    seat: CPt
}

struct Held {
    seat: Pt

    // a struct method that writes its own storage is an `inout fn`; `self`
    // is never rebindable, so "use var" named nothing the language has
    fn seat_it() {
        self.seat.x = 1
    }
}

fn make() -> Rect {
    return Rect { origin: Pt { x: 1, y: 2 } }
}

fn main() {
    // a let's fields stay frozen through any number of hops
    let frozen: Rect = Rect { origin: Pt { x: 1, y: 2 } }
    frozen.origin.x = 9

    // a temporary has no storage to write back to
    make().origin.x = 5

    // a List element read answers a copy
    var rows: List<Rect> = [Rect { origin: Pt { x: 1, y: 2 } }]
    rows[0].origin.x = 7

    // and so does a Map value read
    var table: Map<string, Rect> = {}
    table["a"] = Rect { origin: Pt { x: 1, y: 2 } }
    table["a"].origin.x = 8

    // a union field read reinterprets bytes rather than naming a place
    unsafe {
        var bits: Bits = Bits { whole: 0 }
        bits.seat.x = 1
    }

    io.println("{frozen.origin.x} {rows.len()} {table.len()}")
}
