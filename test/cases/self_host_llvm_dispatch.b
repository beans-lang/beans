// Interface dispatch through the self-host LLVM emitter: descriptors
// carry one slot per dispatchable name, an interface call loads its
// slot through the object's own table, a default body serves classes
// that skip the override, and an overridden class method dispatches
// even through a base-typed receiver.
import std.io

interface Greeter {
    fn name() -> string
    fn greet() -> string {
        return "hi {self.name()}"
    }
}

class Robot implements Greeter {
    tag: string

    fn init(tag: string) {
        self.tag = tag
    }

    fn name() -> string {
        return self.tag
    }
}

class Pirate implements Greeter {
    fn init() {}

    fn name() -> string {
        return "redbeard"
    }

    override fn greet() -> string {
        return "arr, {self.name()}"
    }
}

class Animal {
    fn init() {}

    fn speak() -> string {
        return "..."
    }
}

class Dog extends Animal {
    pub fn init() { super.init() }

    override fn speak() -> string {
        return "woof"
    }
}

fn hear(beast: Animal) -> string {
    return beast.speak()
}

fn main() {
    let crew: List<Greeter> = [new Robot("r2"), new Pirate()]
    for member: Greeter in crew {
        io.println(member.greet())
    }
    let solo: Greeter = new Robot("c3po")
    io.println(solo.name())
    io.println(hear(new Animal()))
    io.println(hear(new Dog()))
}
