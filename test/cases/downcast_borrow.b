// `x as? T` retains what the Option wraps, because the Option owns it and the
// source could die while an arm runs. When the source is a local that holds an
// owned reference and provably never changes, escapes or is captured, that
// retain and its matching release cancel — the local keeps the object alive
// across the whole match by itself.
//
// Every function below is named in test/downcast_borrow.sh, which greps the
// MIR: the elided ones must say borrow-elided and the rest must not. Getting
// that backwards is a leak or a use-after-free, so the negatives carry as much
// weight as the positives.
package main

import std.io

class Shape {
    tag: int

    fn init(tag: int) {
        self.tag = tag
    }

    fn deinit() {
        io.println("gone{self.tag}")
    }
}

class Dot extends Shape {
    fn init(tag: int) {
        super.init(tag)
    }
}

// elided: a plain read, nothing escapes
fn reads() {
    let held: Shape = new Dot(1)
    match held as? Dot {
        some(dot) => { io.println("read {dot.tag}") }
        none => {}
    }
}

// elided: the inner source is the outer binding, which is itself a borrow
fn nested() {
    let held: Shape = new Dot(2)
    match held as? Dot {
        some(outer) => {
            let inner: Shape = outer
            match inner as? Dot {
                some(deep) => { io.println("nested {deep.tag}") }
                none => {}
            }
        }
        none => {}
    }
}

// kept: the source is a borrowed parameter, and nothing here can prove what
// the caller does with its slot for the duration of the call
fn parameter(held: Shape) {
    match held as? Dot {
        some(dot) => { io.println("param {dot.tag}") }
        none => {}
    }
}

// kept: the source is reassigned while the binding is live
fn reassigned() {
    var held: Shape = new Dot(3)
    match held as? Dot {
        some(dot) => {
            held = new Dot(4)
            io.println("reassigned {dot.tag}")
        }
        none => {}
    }
    io.println("after {held.tag}")
}

// kept: the binding outlives the arm inside a closure
fn captured() {
    let held: Shape = new Dot(5)
    var later: fn() -> int = fn() -> int { return 0 }
    match held as? Dot {
        some(dot) => { later = fn() -> int { return dot.tag } }
        none => {}
    }
    io.println("captured {later()}")
}

// kept: the Option lands in a local, so its uses are not just this match
fn to_local() {
    let held: Shape = new Dot(6)
    let maybe: Option<Dot> = held as? Dot
    match maybe {
        some(dot) => { io.println("local {dot.tag}") }
        none => {}
    }
}

// the miss path still answers, and releases nothing it did not take
fn misses() {
    let held: Shape = new Shape(7)
    match held as? Dot {
        some(dot) => { io.println("unexpected {dot.tag}") }
        none => { io.println("missed") }
    }
}

fn main() {
    reads()
    nested()
    parameter(new Dot(8))
    reassigned()
    captured()
    to_local()
    misses()
    io.println("done")
}
