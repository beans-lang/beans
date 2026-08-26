// A record holding an `Option` of another record, stored in a List.
//
// `type_alignment` had no Option case, so it fell through to a rule that
// answers a scalar's alignment — its size. `Option<f32>` came back 8-aligned
// instead of 4, a record holding one was computed 40 bytes where LLVM lays it
// out in 32, and the list stride was eight bytes wider than the element.
// Every element after the first then read partly from its neighbour: the
// `int` fields printed plausible-looking integers, the `Option` fields read
// as none, and nothing was reported. Only element 0 was ever right.
//
// So the list here has to be long enough for the drift to show, and the
// fields have to be printed rather than just compared.
package main

import std.io

pub struct Inner {
    pub thickness: Option<f32> = none
    pub wavy: bool = false
}

pub struct Outer {
    pub start: int = 0
    pub end: int = 0
    pub under: Option<Inner> = none
}

fn thickness_of(o: Outer) -> string {
    match o.under {
        some(u) => {
            match u.thickness {
                some(v) => { return "{v}" }
                none => { return "no-thickness" }
            }
        }
        none => { return "no-under" }
    }
}

fn main() {
    var runs: List<Outer> = []
    var i: int = 0
    for i < 9 {
        runs.push(Outer {
            start: i,
            end: i + 1,
            under: some(Inner { thickness: some(2.0), wavy: i == 3 }),
        })
        i += 1
    }
    for o: Outer in runs {
        io.println("{o.start}..{o.end} {thickness_of(o)}")
    }

    // the wavy flag rides in the same record and drifts the same way
    var wavy_at: int = 0 - 1
    var index: int = 0
    for index < runs.len() {
        match runs[index].under {
            some(u) => { if u.wavy { wavy_at = index } }
            none => {}
        }
        index += 1
    }
    io.println("wavy at {wavy_at} of {runs.len()}")
}
