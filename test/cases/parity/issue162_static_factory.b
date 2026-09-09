// #162: a static factory on a generic class, with the class's type parameter
// bound at the call. Before, no call could bind it and the member was
// unreachable; the two backends never got the chance to disagree about it.
//
// They can now, and this is where they would. A static is monomorphized per
// instantiation on the native side and interpreted from one body with a type
// frame on the other, so a promoted parameter is exactly the kind of thing the
// two get to answer differently: which body runs, what the result type is, and
// — because the payload here is a reference-counted class — when the value it
// builds is released.
//
// Five Loud values are built and five released: one through `wrap`, one
// through a static that reaches another static, one held in the `List<T>` a
// static returns, one moved through a move-only parameter, and one copied into
// both fields of a generic struct's factory result. `wrap` is also called at a
// second instantiation, `Holder<int>`, which builds nothing — that one is here
// so the two instantiations of one static exist side by side. The markers pin
// the count, so a promoted parameter that made a factory run twice on BOTH
// backends would still fail here, which a backend-to-backend diff cannot see.
package main

import std.io

class Loud {
    tag: string = ""

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }
}

class Holder<T> {
    value: Option<T> = none

    fn init() {}

    // the class's T, from an argument and in the result
    static fn wrap(value: T) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = some(value)
        return held
    }

    // the same parameter, still open, threaded through a second static
    static fn empty() -> Holder<T> { return new Holder<T>() }

    static fn wrap_via_empty(value: T) -> Holder<T> {
        let held: Holder<T> = Holder.empty()
        held.value = some(value)
        return held
    }

    // T nested in the result
    static fn one(value: T) -> List<T> { return [value] }
}

// a move-only owner parameter: every T-bearing input must be a move parameter
class Owned<T> {
    value: Option<T> = none

    fn init() {}

    static fn hold(move value: T) -> Owned<T> {
        let box: Owned<T> = new Owned<T>()
        box.value = some(move value)
        return box
    }
}

struct Twin<T> {
    left: T
    right: T

    static fn of(value: T) -> Twin<T> {
        return Twin { left: value, right: value }
    }
}

fn run() {
    // T bound to a reference at one instantiation, to a scalar at another
    let loud: Holder<Loud> = Holder.wrap(new Loud("wrap"))
    let numbers: Holder<int> = Holder.wrap(41)
    io.println("wrapped {numbers.value.expect("n")} {loud.value.expect("l").tag}")

    // one static reaching another with T still open
    let chained: Holder<Loud> = Holder.wrap_via_empty(new Loud("chain"))
    io.println("chained {chained.value.expect("c").tag}")

    // the expected result is the only place T can be read from
    let blank: Holder<Loud> = Holder.empty()
    io.println("blank {blank.value.is_some()}")

    // T nested inside the result
    let listed: List<Loud> = Holder.one(new Loud("listed"))
    io.println("listed {listed.len()}")

    // a move-only payload through a move parameter
    let raw: List<Loud> = [new Loud("moved")]
    let moved: Owned<List<Loud>> = Owned.hold(move raw)
    io.println("moved {moved.value.is_some()}")

    // a generic struct's factory, T bound to a reference the struct copies
    let twin: Twin<Loud> = Twin.of(new Loud("twin"))
    io.println("twin {twin.left.tag}{twin.right.tag}")
}

fn main() {
    run()
    io.println("done")
}
