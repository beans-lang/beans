// `_` is a discard, not a name. Two of them may share a scope, none of them
// can be read — and the value each one takes is still owned, so it is
// released exactly once at the end of the scope it was bound in.
//
// That last part is the half a diff of answers cannot see: a discard that
// forgot to own its value would leak it, and one that dropped it twice would
// release it twice. Both show up here as unbalanced markers, on both
// backends, which is why this case lives beside the other ownership cases.
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

enum Shape {
    dot,
    line(a: Loud, b: Loud),
    tri(a: int, b: int, c: int)
}

// two discards in one parameter list, and one of them owns its argument
fn eat(move _: Loud, kept: int, _: int) -> int {
    io.println("eat {kept}")
    return kept
}

fn main() {
    // two discards in one scope, each dropped at the end of that scope
    let _: Loud = new Loud("first")
    let _: Loud = new Loud("second")
    io.println("bound")

    // a discarded move parameter drops at the callee's exit
    io.println("ate {eat(new Loud("eaten"), 7, 8)}")

    // a discard inside a loop drops each turn, not at the end
    for index: int in 0..2 {
        let _: Loud = new Loud("turn{index}")
        io.println("turn {index}")
    }

    // several discards in one pattern; the payload is borrowed, so the
    // shape's own values are released with the shape and not by the arm
    let shape: Shape = Shape.line(new Loud("left"), new Loud("right"))
    let name: string = match shape {
        dot => "dot",
        line(_, _) => "line",
        tri(_, _, _) => "tri",
    }
    io.println("matched {name}")

    // a discard in a loop binding, and one in a closure parameter
    var seen: int = 0
    for _: int in 0..3 { seen += 1 }
    let ignore: fn(int, int) -> int = fn(_: int, keep: int) -> int {
        return keep
    }
    io.println("seen {seen} kept {ignore(1, 4)}")
}
