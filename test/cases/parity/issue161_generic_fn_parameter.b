// Issue #161: a generic whose type parameter sits inside a function-typed
// parameter. The native backend refused the call — "LLVM emitter cannot infer
// this generic call's types" — for a free function and for a static, while an
// instance method with the identical signature emitted, and the interpreter
// ran all three. So the two backends could not be compared on this shape at
// all until the emitter could raise the instance.
//
// Answers alone would not carry it: what a closure passed to a generic does
// is build and release values, so the markers are the claim. Both backends
// have to invoke the closure the same number of times, release what it built
// once each, and release the value carried through `fn(T) -> T` exactly once
// as it is replaced.
package main

import std.io

class Cell {
    tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
}

// the reported shape: `fn(T)`, result left unwritten
fn drive<T>(rounds: int, value: T, setup: fn(T)) -> int {
    var index: int = 0
    for index < rounds {
        setup(value)
        index += 1
    }
    return rounds
}

// the same, with the result spelled: one type, two spellings, and the
// argument may be written either way
fn drive_spelled<T>(rounds: int, value: T,
                    setup: fn(T) -> unit) -> int {
    var index: int = 0
    for index < rounds {
        setup(value)
        index += 1
    }
    return rounds
}

// T in the function type's result: each step hands back an owned value and
// the one it replaces has to be released, once, on both backends
fn fold<T>(value: T, step: fn(T) -> T, rounds: int) -> T {
    var carried: T = value
    var index: int = 0
    for index < rounds {
        carried = step(carried)
        index += 1
    }
    return carried
}

// T reachable ONLY through function types: nothing else in either signature
// mentions it, so binding it is the function type's job alone. This is the
// half an explicit type argument cannot cover.
fn count_with<T>(rounds: int, make: fn() -> T) -> int {
    var index: int = 0
    for index < rounds {
        let made: T = make()
        index += 1
    }
    return rounds
}

fn feed<T>(make: fn() -> T, setup: fn(T)) -> int {
    let value: T = make()
    setup(value)
    return 1
}

// A type parameter that shadows a class name. Which names are type variables
// is the template's own business: resolving the name instead finds the class,
// so the parameter read as a concrete type and the call was refused at build
// time while the interpreter ran it.
fn shadow_apply<Cell>(value: Cell, setup: fn(Cell)) -> int {
    setup(value)
    return 1
}

class Host {
    fn init() {}
    // the receiver form that already emitted
    fn apply<T>(rounds: int, value: T, setup: fn(T)) -> int {
        var index: int = 0
        for index < rounds {
            setup(value)
            index += 1
        }
        return rounds
    }
    // the one that did not
    static fn stat_apply<T>(rounds: int, value: T,
                            setup: fn(T)) -> int {
        var index: int = 0
        for index < rounds {
            setup(value)
            index += 1
        }
        return rounds
    }
}

class Holder<T> {
    held: T
    fn init(held: T) { self.held = held }
    // a static of a generic class, through the bare class name
    static fn stat_apply<U>(value: U, setup: fn(U)) -> int {
        setup(value)
        return 1
    }
}

fn main() {
    let seed: Cell = new Cell("seed")

    // A — the free function, at a class argument and at an int argument.
    // The closure builds a value per round, so a body invoked the wrong
    // number of times is a marker imbalance rather than a silent pass.
    io.println("A {drive<Cell>(3, seed, fn(x: Cell) { let t: Cell = new Cell("a") })}")
    var total: int = 0
    io.println("A {drive<int>(2, 5, fn(v: int) { total += v })} {total}")

    // A — the same call with no explicit type argument, which the checker
    // used to refuse for the same reason the emitter did
    io.println("A {drive(2, seed, fn(x: Cell) { let t: Cell = new Cell("b") })}")

    // B — parameter spells the result, argument does not, and the reverse
    let via: fn(Cell) = fn(x: Cell) { let t: Cell = new Cell("c") }
    io.println("B {drive_spelled<Cell>(2, seed, via)}")
    io.println("B {drive<Cell>(1, seed, fn(x: Cell) { let t: Cell = new Cell("d") })}")

    // C — a value carried through `fn(T) -> T`: two new cells, and the one
    // replaced each round released as it goes
    let folded: Cell =
        fold<Cell>(seed, fn(x: Cell) -> Cell { return new Cell("e") }, 2)
    io.println("C {folded.tag}")

    // D — every receiver form: instance, static, and the static of a
    // generic class
    let host: Host = new Host()
    io.println("D {host.apply<Cell>(2, seed, fn(x: Cell) { let t: Cell = new Cell("f") })}")
    io.println("D {Host.stat_apply<Cell>(2, seed, fn(x: Cell) { let t: Cell = new Cell("g") })}")
    let holder: Holder<int> = new Holder<int>(9)
    io.println("D {Holder.stat_apply<Cell>(seed, fn(x: Cell) { let t: Cell = new Cell("h") })} {holder.held}")

    // E — T bound through the function type and nowhere else, with the
    // value the callback builds released each round
    io.println("E {count_with<Cell>(2, fn() -> Cell { return new Cell("i") })}")
    io.println("E {count_with(2, fn() -> Cell { return new Cell("j") })}")
    io.println("E {feed(fn() -> Cell { return new Cell("k") }, fn(x: Cell) { let t: Cell = new Cell("l") })}")

    // F — a type parameter shadowing a class name, at two arguments, with
    // the shadowed name inside the function type as well
    io.println("F {shadow_apply(seed, fn(x: Cell) { let t: Cell = new Cell("m") })}")
    io.println("F {shadow_apply<int>(3, fn(v: int) { total += v })} {total}")

    io.println("done")
}
