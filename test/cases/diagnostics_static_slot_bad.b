// A `static fn` has no `self`, so no receiver can pick it and no descriptor
// row may name it. Every declaration below used to check clean and then hand
// a receiver to a function that declares none: the subclass's static took
// over the base's instance dispatch slot, and both backends agreed on the
// wrong call (#88).
//
// The rule is the one the spec now states: within one class family a name is
// either a static or an instance method, never both, and a static is called
// on its type rather than on a value.
package main

import std.io

interface Shows {
    fn show() -> string
}

// An interface default is an instance method the implementor keeps, so it
// counts as one for this rule too.
interface Named {
    fn name() -> string { return "Named.name" }
}

class Base {
    fn init() {}

    fn label() -> string { return "Base.label" }
}

// 1. the reported shape — a static beside the instance method it inherits
class Sub extends Base {
    fn init() { super.init() }

    static fn label() -> string { return "Sub.label" }
}

// 2. two links up, which a rule reading only the immediate base would miss
class Mid extends Base {
    fn init() { super.init() }
}

class Leaf extends Mid {
    fn init() { super.init() }

    static fn label() -> string { return "Leaf.label" }
}

// 3. with `override` spelled out. Override checking returned early for a
// static, so this was accepted and replaced nothing.
class Marked extends Base {
    fn init() { super.init() }

    override static fn label() -> string { return "Marked.label" }
}

// 4. the mirror — a static in the base, an instance method below it. The
// base's row named the static and a base-typed receiver reached it, while
// the same call on a subclass reached the instance method.
class Stamped {
    fn init() {}

    static fn stamp() -> string { return "Stamped.stamp" }
}

class Restamped extends Stamped {
    fn init() { super.init() }

    fn stamp() -> string { return "Restamped.stamp" }
}

// 5. against an interface the class implements
class Viewer implements Shows {
    fn init() {}

    static fn show() -> string { return "Viewer.show" }
}

// 6. against an interface default kept one link further down
class Holder implements Named {
    fn init() {}
}

class SubHolder extends Holder {
    fn init() { super.init() }

    static fn name() -> string { return "SubHolder.name" }
}

// 7. no collision at all: a static reached through an instance receiver.
// The call still passed the receiver, and only the target's argument
// registers being ignored kept it from reading it as an argument.
class Solo {
    fn init() {}

    static fn tag() -> string { return "Solo.tag" }
}

fn ask(value: Solo) -> string { return value.tag() }

fn main() {
    io.println(new Sub().label())
    io.println(new Leaf().label())
    io.println(new Marked().label())
    io.println(new Restamped().stamp())
    io.println(new Viewer().show())
    io.println(new SubHolder().name())
    io.println(ask(new Solo()))
}
