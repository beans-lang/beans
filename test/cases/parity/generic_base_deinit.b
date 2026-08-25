// B5 and B6: a class extending a generic base at a concrete argument.
//
// A descriptor names one release symbol per class, found by walking the
// chain for `{owner}.deinit`. A generic base is a template with nothing at
// that name, so the row emitted null and dropping the subclass jumped to
// address zero — a segfault, from a program the interpreter ran correctly.
//
// Raising the base body fixed that, and uncovered the second half: when the
// deriving class writes its own deinit, its body is emitted before any `new`
// site has raised the base, so the chain call had no symbol to name and was
// dropped. The base's release then silently never ran, which prints as a
// missing line here and would be a leak in a program that owned anything.
//
// Both halves are invisible to a test that compares answers: `get()` returns
// the right value either way. Only the release markers show it.
package main

import std.io

class Holder<T> {
    pub held: T

    fn init(held: T) {
        self.held = held
        io.println("arc+base")
    }

    fn deinit() { io.println("arc-base") }

    pub fn get() -> T { return self.held }
}

// no deinit of its own: the raised base body is this class's release
class IntHolder extends Holder<int> {
    fn init() { super.init(4) }
}

// its own deinit, which has to chain into the raised base on the way out
class NamedHolder extends Holder<string> {
    fn init() {
        super.init("named")
        io.println("arc+sub")
    }

    fn deinit() { io.println("arc-sub") }

    pub fn tag() -> string { return "named" }
}

fn main() {
    let a: IntHolder = new IntHolder()
    io.println("int {a.get()}")

    let b: NamedHolder = new NamedHolder()
    io.println("named {b.get()} {b.tag()}")

    // the generic base used directly, at the argument one subclass pins
    let c: Holder<int> = new Holder<int>(9)
    io.println("direct {c.get()}")
}
