// `Table.seed(1)` was refused with "main.Table has no static 'seed'" — a
// message that was never true. The static was declared right there, reading
// it into a local and calling that local worked, and the same call through an
// INSTANCE field had always been accepted. Only the static branch of call
// resolution lacked the fallback: it looked for a static method of that name,
// found none, and reported the name missing rather than looking at the
// static fields.
//
// A static method still wins over a static field of the same name, which is
// what `pick` and `pick_via` check below.
package main

import std.io

class Table {
    static bump: fn(int) -> int = fn(x: int) -> int { return x + 1 }
    static make: fn() -> int = fn() -> int { return 7 }
    static pick: fn(int) -> int = fn(x: int) -> int { return x + 100 }

    static fn pick_via(n: int) -> int {
        return n
    }
}

class Wide {
    static join: fn(string, int) -> string =
        fn(text: string, n: int) -> string { return "{text}:{n}" }
}

fn main() {
    // called directly, with and without arguments
    io.println("direct {Table.bump(1)} {Table.make()}")

    // the old workaround has to keep answering the same thing
    let held: fn(int) -> int = Table.bump
    io.println("held {held(1)}")

    // a static method of a nearby name is untouched
    io.println("method {Table.pick(1)} {Table.pick_via(2)}")

    // more than one parameter, and a non-scalar one
    io.println("wide {Wide.join("k", 3)}")

    // the result feeds an expression rather than a print of its own
    let total: int = Table.bump(1) + Table.make()
    io.println("total {total}")
}
