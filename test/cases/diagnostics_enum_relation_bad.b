// Only a class is an interface value: an interface receiver is dispatched by
// reading a descriptor out of the object's first word, and an enum value is a
// tag. Every spelling below passed the checker before #87, and then answered
// unit under the interpreter while the native build read the tag word as a
// descriptor and jumped through it.
package main

import std.io

interface Shows {
    fn show() -> string
}

interface Names {
    fn name() -> string
}

class Holder {
    fn init() {}
}

// payload-free, one interface — the reported shape
enum Colour implements Shows {
    red
    green

    pub fn show() -> string { return "colour" }
}

// two interfaces at once, so each is named on its own line
enum Signal implements Shows, Names {
    up
    down

    pub fn show() -> string { return "signal" }

    pub fn name() -> string { return "signal" }
}

// payload variants, which are objects and still not interface values
enum Payment implements Shows {
    cash
    card(number: string)

    pub fn show() -> string { return "payment" }
}

// a committed one-byte layout, which has no room for a descriptor at all
enum(u8) Display implements Shows {
    flex
    grid

    pub fn show() -> string { return "display" }
}

// a generic enum
enum Cell<T> implements Shows {
    empty
    full(value: T)

    pub fn show() -> string { return "cell" }
}

// a base class, which an enum has no room for either
enum Rooted extends Holder {
    one
    two
}

fn ask(value: Shows) -> string { return value.show() }

fn main() {
    // every way an enum value could reach an interface-typed slot
    io.println(ask(Colour.red))
    let single: Shows = Signal.up
    var many: List<Shows> = [Colour.red, Signal.up]
    var by_key: Map<int, Shows> = {}
    by_key[0] = Payment.cash
    io.println("rendered {single.show()} {many[0].show()}")
    io.println("{by_key[0].show()}")
}
