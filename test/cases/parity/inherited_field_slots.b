// #95: a subclass field must not reuse a base field's name. The two backends
// used to lay a redeclared name out differently — the interpreter gave the
// base and the subclass one slot and destroyed the base's value during
// construction, a native build gave each its own. The checker now refuses the
// redeclaration; this is the legitimate shape it must still accept and both
// backends must still agree on: a subclass whose added fields carry their own
// names. Every field of every class in the chain owns a slot, so four owned
// values build once and release once, in the one reverse-declaration order
// the two backends share (k, h, g, f -> 4, 3, 2, 1).
package main

import std.io

class Loud {
    id: int = 0

    fn init(id: int) {
        self.id = id
        io.println("arc+{id}")
    }

    fn deinit() { io.println("arc-{self.id}") }
}

class Base {
    f: Option<Loud> = none
    g: Option<Loud> = none

    fn init(a: Loud, b: Loud) {
        self.f = some(a)
        self.g = some(b)
    }
}

class Derived extends Base {
    h: Option<Loud> = none
    k: Option<Loud> = none

    fn init(a: Loud, b: Loud, c: Loud, d: Loud) {
        self.h = some(c)
        self.k = some(d)
        super.init(a, b)
    }
}

fn run() {
    var v: Derived =
        new Derived(new Loud(1), new Loud(2), new Loud(3), new Loud(4))
    io.println("built")
}

fn main() { run() }
