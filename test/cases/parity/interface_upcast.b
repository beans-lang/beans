// B4: the native backend refused a class -> interface upcast at a `return`
// while the interpreter took it, so a whole package that returned an
// interface would run but not build. Every other position — argument, list
// element, `some(...)`, a `let` of interface type — already lowered it; the
// MIR verifier walked only `extends` and bailed on generic arguments.
//
// The `+tag` / `-tag` markers put construct and drop counts into the compared
// output. Comparing printed answers alone cannot see a value built twice or
// released twice, which is the shape of bug this file exists to catch.
package main

import std.io

interface Shape {
    fn name() -> string
}

interface Solid extends Shape {
    fn mass() -> int
}

class Dot implements Shape {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    pub fn name() -> string { return self.tag }
}

class Rock implements Solid {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    pub fn name() -> string { return self.tag }

    pub fn mass() -> int { return 5 }
}

class Pebble extends Rock {
    fn init() { super.init("pebble") }

    pub override fn name() -> string { return "pebble" }
}

interface Producer<T> {
    fn make() -> T
}

class IntBox implements Producer<int> {
    fn init() {}

    pub fn make() -> int { return 7 }
}

// the interface the class names directly
fn as_shape() -> Shape { return new Dot("dot") }

// the parent of the interface the class names
fn as_parent() -> Shape { return new Rock("rock") }

// an interface reached through the base class
fn as_inherited() -> Shape { return new Pebble() }

// a local still typed as the class at the point of return
fn as_local() -> Shape {
    let d: Dot = new Dot("local")
    return d
}

// the base class itself, which the extends walk already allowed
fn as_base() -> Rock { return new Pebble() }

// a generic interface at a concrete argument
fn as_generic() -> Producer<int> { return new IntBox() }

fn main() {
    io.println("shape {as_shape().name()}")
    io.println("parent {as_parent().name()}")
    io.println("inherited {as_inherited().name()}")
    io.println("local {as_local().name()}")
    io.println("base {as_base().name()} {as_base().mass()}")
    io.println("generic {as_generic().make()}")
}
