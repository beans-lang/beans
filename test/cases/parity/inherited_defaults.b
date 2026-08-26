// Default bodies reached the long way round, both of which the two backends
// answered differently.
//
//   * An `override` default supplied by a sub-interface was invisible to the
//     interpreter when the receiver was typed as the SUPER-interface: its
//     dynamic lookup walked `extends` only, and a class reaches its interface
//     through `implements`, so the call fell back to the bodyless declaration
//     the checker had resolved and answered a value with no type at all.
//     Native had always been right — the only fault so far where the
//     interpreter was the wrong half, which matters because goldens are
//     produced by `beansc run`.
//
//   * A generic class keeping an interface's default did not build at all
//     ("no template for"), and once it did, calling it through the interface
//     jumped to address zero: the default belongs to the interface, so it is
//     never raised per instantiation, and the descriptor row stayed null.
package main

import std.io

class Wrapper {
    pub tag: string

    fn init(tag: string) { self.tag = tag }
}

interface Base {
    fn wrap() -> Wrapper
}

interface Middle extends Base {
    pub override fn wrap() -> Wrapper {
        return new Wrapper("from Middle")
    }
}

class Thing implements Middle {
    pub fn init() {}
}

// the same class, overriding the default itself
class Louder implements Middle {
    pub fn init() {}

    pub override fn wrap() -> Wrapper {
        return new Wrapper("from Louder")
    }
}

interface Sized {
    fn width() -> int

    pub fn describe() -> string { return "width {self.width()}" }
}

class Boxy<T> implements Sized {
    pub held: T
    pub w: int

    fn init(held: T, w: int) {
        self.held = held
        self.w = w
    }

    pub fn width() -> int { return self.w }
}

fn main() {
    // the same object reached at three static types
    let thing: Thing = new Thing()
    let middle: Middle = new Thing()
    let base: Base = new Thing()
    io.println("thing {thing.wrap().tag}")
    io.println("middle {middle.wrap().tag}")
    io.println("base {base.wrap().tag}")

    // a class overriding the interface's override still wins
    let louder: Louder = new Louder()
    let as_base: Base = new Louder()
    io.println("louder {louder.wrap().tag} {as_base.wrap().tag}")

    // a generic class keeping a default, at two arguments and both ways round
    let boxed: Boxy<int> = new Boxy<int>(1, 30)
    let sized: Sized = boxed
    io.println("boxy {boxed.describe()} / {sized.describe()}")

    let worded: Boxy<string> = new Boxy<string>("x", 7)
    let worded_sized: Sized = worded
    io.println("worded {worded.describe()} / {worded_sized.describe()}")

    // through a list of the interface, which dispatches from the descriptor
    var all: List<Sized> = [boxed, worded]
    var total: int = 0
    for one: Sized in all {
        total += one.width()
    }
    io.println("total {total} first {all[0].describe()}")
}
