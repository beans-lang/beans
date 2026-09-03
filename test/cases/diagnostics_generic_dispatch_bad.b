// A method that declares type parameters of its own binds them at the call
// site, so it is a template with one function per instantiation and no
// single body a descriptor row could name. Every form below exists only to
// be dispatched, and every one of them checked clean before #89: the row
// stayed null and the native call jumped through it while the interpreter
// answered, or — for a replaced body — native bound the base's template and
// the interpreter dispatched to the subclass's, with nothing said either
// way.
package main

import std.io

class Carrier {
    fn init() {}

    fn pick<T>(value: T) -> T { return value }

    fn plain() -> int { return 0 }
}

// 1. a bodyless interface requirement: an interface is a name for a set of
// classes and the only way to reach one is through a row
interface Picker {
    fn pick<T>(value: T) -> T
}

// 2. an interface default, which the implementor keeps and reaches the same
// way
interface Defaulted {
    fn choose<T>(value: T) -> T { return value }
}

// 3. the same on a generic interface, where the interface's own parameter is
// bound at the `implements` site but the method's is not
interface Producer<E> {
    fn make<T>(value: T) -> E
}

// 4. `abstract fn`, which exists to be replaced and reached through a row
abstract class Chooser {
    fn init() {}

    abstract fn pick<T>(value: T) -> T
}

// 5. replacing an inherited generic method, spelled `override`
class Marked extends Carrier {
    fn init() { super.init() }

    override fn pick<T>(value: T) -> T { return value }
}

// 6. the same without `override`, which used to ask for the keyword and so
// pointed at a replacement that could never happen
class Unmarked extends Carrier {
    fn init() { super.init() }

    fn pick<T>(value: T) -> T { return value }
}

// 7. a plain method replacing an inherited generic one
class Narrowed extends Carrier {
    fn init() { super.init() }

    override fn pick(value: int) -> int { return value }
}

// 8. and a generic method replacing an inherited plain one, which would
// leave the base's row filled and the subclass's body unreachable through it
class Widened extends Carrier {
    fn init() { super.init() }

    override fn plain<T>() -> int { return 1 }
}

// the interface-typed receiver, which is where the null row was read
fn ask(value: Picker) -> int { return value.pick<int>(1) }

fn choose(value: Defaulted) -> int { return value.choose<int>(1) }

fn main() {
    io.println("{new Marked().pick<int>(1)}")
    io.println("{new Unmarked().pick<int>(2)}")
    io.println("{new Narrowed().pick(3)}")
    io.println("{new Widened().plain<int>()}")
}
