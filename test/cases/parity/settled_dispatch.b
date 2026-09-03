// A call the emitter can name outright must do the same work as the call
// through the table it replaces — the same receiver, the same arguments,
// evaluated the same number of times and released the same number of times.
// The two paths build their argument lists in different code: the guarded
// one writes the receiver as a bare pointer and the direct one runs every
// operand, receiver included, through the internal-argument packer. A
// difference there would leak a receiver or release one twice, and a
// backend-to-backend diff of the printed answers could not see it.
//
// The `arc+tag` / `arc-tag` markers put construct and drop counts into the
// compared output, and the pinned total catches a change that runs something
// twice on BOTH backends.
package main

import std.io

// a private method: the slot belongs to Ledger, so this settles
class Ledger {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    priv fn stamp() -> string { return "L" }

    fn record(mark: Mark) -> string {
        return "{self.tag}/{self.stamp()}/{mark.text()}"
    }
}

// an argument that is itself an object, so the settled call has to own and
// release one as well as receive one
class Mark {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    fn text() -> string { return self.tag }
}

// an override, so the same shape keeps going through the table
class Animal {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    fn speak(mark: Mark) -> string {
        return "{self.tag}:{mark.text()}"
    }
}

class Dog extends Animal {
    fn init() { super.init("dog") }

    override fn speak(mark: Mark) -> string {
        return "woof:{mark.text()}"
    }
}

// the sole implementor of an interface, reached at the interface type
interface Only {
    fn once(mark: Mark) -> string
}

class TheOnly implements Only {
    priv tag: string

    fn init() {
        self.tag = "only"
        io.println("arc+only")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    fn once(mark: Mark) -> string {
        return "only/{mark.text()}"
    }
}

fn via_ledger(value: Ledger, mark: Mark) -> string {
    return value.record(mark)
}

fn via_animal(value: Animal, mark: Mark) -> string {
    return value.speak(mark)
}

fn via_only(value: Only, mark: Mark) -> string {
    return value.once(mark)
}

fn main() {
    let ledger: Ledger = new Ledger("led")
    let animal: Animal = new Animal("beast")
    let dog: Dog = new Dog()
    let only: TheOnly = new TheOnly()

    io.println(via_ledger(ledger, new Mark("m1")))
    io.println(via_animal(animal, new Mark("m2")))
    io.println(via_animal(dog, new Mark("m3")))
    io.println(via_only(only, new Mark("m4")))

    // the same calls again through an interface-typed and a base-typed local,
    // so a settled call and a table call see the same receivers twice
    let as_animal: Animal = dog
    let as_only: Only = only
    io.println(via_animal(as_animal, new Mark("m5")))
    io.println(via_only(as_only, new Mark("m6")))
}
