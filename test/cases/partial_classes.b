// A partial class is one class written in more than one place. Every part
// says `partial`, exactly one part may carry the header — modifiers,
// generic parameters, extends and implements — and the members of every
// part belong to the one class the parts describe together.
import std.io

interface Named {
    fn label() -> string
}

class Base {
    fn kind() -> string { return "base" }
}

// The header. It is written here, but nothing requires it to come first:
// the parts below could hold it instead and the class would be the same.
pub partial class Robot extends Base implements Named {
    id: int
    static made: int = 0
    fn init(id: int) {
        self.id = id
        Robot.made += 1
    }
}

// A continuation may declare fields, and a field default travels with it.
partial class Robot {
    tag: string = "none"
    fn label() -> string { return "robot-{self.id}/{self.tag}" }
}

// An interface method, an override and a static may all live in a part
// other than the one that named the interface or the base class.
partial class Robot {
    override fn kind() -> string { return "robot" }
    static fn built() -> int { return Robot.made }
}

// Generic parameters belong to the header; a continuation of a generic
// class is written bare and still sees the parameter.
partial class Crate<T> {
    items: List<T>
    fn init() { self.items = [] }
    fn add(item: T) { self.items.push(item) }
}

partial class Crate {
    fn size() -> int { return self.items.len() }
}

// No part has to carry a header at all. Field order follows the order the
// parts are declared in.
partial class Pair {
    left: int
}

partial class Pair {
    right: int
    fn total() -> int { return self.left + self.right }
}

fn main() {
    let a: Robot = new Robot(1)
    a.tag = "alpha"
    let b: Robot = new Robot(2)
    io.println(a.label())
    io.println(b.label())
    io.println(a.kind())
    io.println("built {Robot.built()}")

    // The interface is satisfied by a method written in a continuation.
    let named: Named = a
    io.println(named.label())

    let numbers: Crate<int> = new Crate<int>()
    numbers.add(4)
    numbers.add(9)
    io.println("crate {numbers.size()}")

    let words: Crate<string> = new Crate<string>()
    words.add("x")
    io.println("crate {words.size()}")

    let pair: Pair = new Pair()
    pair.left = 3
    pair.right = 4
    io.println("pair {pair.total()}")
}
