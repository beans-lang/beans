// A class that extends a closed generic and writes no `init` of its own.
// `beansc check` passed, `beansc run` printed the right answer, and only
// `beansc build` refused — "LLVM emitter cannot find initializer
// 'main::Grid.init'", a message about the emitter's internals for ordinary
// user code with no reflection in it (#172). A generic class's bodies are
// raised under the rendered instance name, `main.Grid<int>.init`, while the
// lookup asked for the declaration's open name.
//
// The gate has to BUILD, not only check and run: a case that stops at `run`
// passes on the broken tree, which is how this survived. The parity runner
// does all three legs, which is why the case lives here.
//
// The control that writes `fn init` beside every shape is the point: the
// only difference between a program that built and one that did not was
// whether the subclass declared an initializer, so a case with only the
// inheriting shapes cannot say which half is being tested.
package main

import std.io

class Grid<T> {
    tag: string = ""
    title: string = ""
    fn init(tag: string) {
        self.tag = tag
        self.title = "grid:{tag}"
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    pub fn describe() -> string { return self.title }
}

// inherits the base's init, base init takes an argument
class Inherit extends Grid<int> { start: int = 41 }

// the control: the same class writing one
class OwnInit extends Grid<int> {
    start: int = 41
    fn init(tag: string) { super.init(tag) }
}

// a middle link that declares none either, so the walk passes through two
class Middle extends Inherit { extra: int = 7 }

// a second instantiation of the same generic base
class OtherArg extends Grid<string> { s: string = "d" }

// the subclass is itself generic, and inherits across its own parameter
class StillGeneric<U> extends Grid<U> { n: int = 3 }

// a zero-argument init, inherited
class Zero<T> {
    tag: string = ""
    z: int = 0
    fn init() {
        self.tag = "zero"
        self.z = 9
        io.println("arc+zero")
    }
    fn deinit() { io.println("arc-{self.tag}") }
}
class InheritZero extends Zero<int> { f: int = 1 }

// an interface on the inheriting class, so the dispatch rows and the
// initializer lookup are exercised on the same object
interface Shown { fn show() -> string }
class WithInterface extends Grid<int> implements Shown {
    pub fn show() -> string { return self.title }
}

fn main() {
    let a: Inherit = new Inherit("inherit")
    io.println("inherit: {a.title} {a.start} {a.describe()}")

    let b: OwnInit = new OwnInit("own")
    io.println("own: {b.title} {b.start}")

    let c: Middle = new Middle("middle")
    io.println("middle: {c.title} {c.start} {c.extra}")

    let d: OtherArg = new OtherArg("other")
    io.println("other: {d.title} {d.s}")

    let e: StillGeneric<int> = new StillGeneric<int>("gen-int")
    io.println("gen-int: {e.title} {e.n}")
    let f: StillGeneric<string> = new StillGeneric<string>("gen-str")
    io.println("gen-str: {f.title} {f.n}")

    let g: InheritZero = new InheritZero()
    io.println("zero: {g.z} {g.f}")

    let h: WithInterface = new WithInterface("iface")
    io.println("iface: {h.show()}")

    // held at the base, so the object is built through the inherited
    // initializer and released through the base's deinit
    let held: Grid<int> = new Inherit("held")
    io.println("held: {held.describe()}")
}
