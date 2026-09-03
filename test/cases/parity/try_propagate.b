// `?` propagating out of a function whose Option or Result is not the one it
// unwrapped. The two kinds are asymmetric and the emitter had only written
// one of them down: a Result carries its error across, so the propagation
// extracts the payload and rewraps it, while an Option carries nothing at
// all — `none` is `none` whatever the two payload types are.
//
// The Option case fell through to the Result code, which read an "error
// payload" at offset 8 of a value that has none and answered a fresh heap
// box where a tagged pair belonged. The module did not verify, so `beansc
// build` failed naming a .ll file while the interpreter ran the program
// correctly. Everything here is a program the checker already accepted.
//
// The markers are on the Result side, where a propagated error is a real
// value that has to cross exactly once and die exactly once. The Option side
// has nothing to count, which is the whole point of it.
package main

import std.io

class Boom {
    pub code: int

    fn init(code: int) {
        self.code = code
        io.println("arc+boom{code}")
    }

    fn deinit() { io.println("arc-boom{self.code}") }
}

class Cell {
    pub n: int = 7
}

fn maybe_int(hit: bool) -> Option<int> {
    if hit { return some(3) }
    return none
}

fn maybe_cell(hit: bool) -> Option<Cell> {
    if hit { return some(new Cell()) }
    return none
}

fn faulty(hit: bool, code: int) -> Result<int, Boom> {
    if hit { return ok(5) }
    return err(new Boom(code))
}

// Option<int> -> Option<string>: the payload type changes and there is
// nothing to carry
fn widen_int(hit: bool) -> Option<string> {
    let n: int = maybe_int(hit)?
    return some("n{n}")
}

// Option<Cell> -> Option<int>: the source is represented as a bare pointer
// and the target as a tagged pair, which is the shape that produced invalid
// IR. Only the propagating side is taken here, because a reference unwrapped
// out of an Option is leaked natively (beans-lang/beans#110) and that is a
// fault in the unwrap, not in the propagation.
fn narrow_cell(hit: bool) -> Option<int> {
    if hit { return some(1) }
    let cell: Cell = maybe_cell(false)?
    return some(cell.n)
}

// Option<int> -> Option<int>: the representations match, so the value flows
// straight out and keeps its ownership
fn same_int(hit: bool) -> Option<int> {
    let n: int = maybe_int(hit)?
    return some(n + 1)
}

// Result<int, Boom> -> Result<string, Boom>: the error is a real value and
// crosses the boundary
fn widen_result(hit: bool, code: int) -> Result<string, Boom> {
    let n: int = faulty(hit, code)?
    return ok("r{n}")
}

fn show_option(tag: string, value: Option<string>) {
    match value {
        some(text) => { io.println("{tag} {text}") }
        none => { io.println("{tag} none") }
    }
}

fn show_int(tag: string, value: Option<int>) {
    match value {
        some(n) => { io.println("{tag} {n}") }
        none => { io.println("{tag} none") }
    }
}

fn main() {
    show_option("widen", widen_int(true))
    show_option("widen", widen_int(false))
    show_int("narrow", narrow_cell(true))
    show_int("narrow", narrow_cell(false))
    show_int("same", same_int(true))
    show_int("same", same_int(false))
    match widen_result(true, 1) {
        ok(text) => { io.println("result {text}") }
        err(boom) => { io.println("result boom{boom.code}") }
    }
    match widen_result(false, 2) {
        ok(text) => { io.println("result {text}") }
        err(boom) => { io.println("result boom{boom.code}") }
    }
    io.println("end")
}
