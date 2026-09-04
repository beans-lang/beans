// `?` is the one place the emitter takes a value apart and has to decide who
// keeps its count, and it was reading that decision out of the wrong place.
//
// The ownership plan already answers it. `consumes` on the instruction means
// the operand's count is the result's and nothing else will release it; no
// `consumes` means the operand keeps its own and an owned result needs one of
// its own. The unwrap's Option arms retained the payload either way, so every
// reference that crossed an owned `?` was left with a +1 nothing released
// (beans-lang/beans#110) — the interpreter freed it and the native backend
// did not. The propagate's same-representation path had the mirror fault: the
// operand flowed straight out even when it was a borrow, handing the caller a
// box this function never retained.
//
// So every shape below appears twice, over an owned temporary and over a
// borrow, because the two halves fail in opposite directions: a fix that
// stops retaining everywhere passes the first half and double-frees on the
// second, and the retain this file pins is the one the borrow still needs.
package main

import std.io

class Cell {
    pub n: int = 0
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }
}

// a payload that owns a reference without being one: the unwrap takes the
// other Option arm for it, which had the same fault for the same reason
struct Crate {
    c: Cell
}

class Holder {
    pub slot: Option<Cell>

    fn init(tag: string) { self.slot = some(new Cell(tag)) }
}

fn fresh(tag: string) -> Option<Cell> {
    return some(new Cell(tag))
}

fn crated(tag: string) -> Option<Crate> {
    return some(Crate { c: new Cell(tag) })
}

fn faulty(tag: string) -> Result<Cell, Cell> {
    return err(new Cell(tag))
}

fn made(tag: string) -> Result<Cell, Cell> {
    return ok(new Cell(tag))
}

fn count(c: Cell) -> int { return c.n }

// the shape that already worked, kept as the reading everything else must
// match: a match arm binds the payload and the value dies with the arm
fn by_match() {
    match fresh("match") {
        some(c) => { io.println("  match {c.n}") }
        none => {}
    }
}

// an owned temporary: the operand is consumed, so its count is the result's
fn owned_dropped() -> Option<int> {
    let c: Cell = fresh("owned")?
    io.println("  owned {c.n}")
    return some(1)
}

// the same, with the unwrapped value handed back out again
fn owned_returned() -> Option<Cell> {
    let c: Cell = fresh("returned")?
    io.println("  returned {c.n}")
    return some(c)
}

// a borrow of a local: the operand keeps its count and the owned result
// takes one of its own
fn borrowed_local() -> Option<int> {
    let held: Option<Cell> = fresh("local")
    let c: Cell = held?
    io.println("  local {c.n}")
    return some(2)
}

// a borrow of a parameter
fn borrowed_parameter(held: Option<Cell>) -> Option<int> {
    let c: Cell = held?
    io.println("  parameter {c.n}")
    return some(3)
}

// a borrow of a field
fn borrowed_field() -> Option<int> {
    let holder: Holder = new Holder("field")
    let c: Cell = holder.slot?
    io.println("  field {c.n}")
    return some(4)
}

// a payload that is not itself a reference but owns one
fn owned_struct() -> Option<int> {
    let crate: Crate = crated("struct")?
    io.println("  struct {crate.c.n}")
    return some(5)
}

// read straight off the `?` with nothing bound
fn read_through() -> Option<int> {
    io.println("  read {fresh("read")?.n}")
    return some(6)
}

// write straight through the `?`
fn write_through() -> Option<int> {
    fresh("write")?.n = 9
    return some(7)
}

// the unwrapped value as a call argument
fn argument() -> Option<int> {
    io.println("  argument {count(fresh("argument")?)}")
    return some(8)
}

// three turns, so a count that is right only for one is not right here
fn looped() -> Option<int> {
    var total: int = 0
    for turn: int in 0..3 {
        let c: Cell = fresh("loop{turn}")?
        total = total + c.n + turn
    }
    io.println("  loop {total}")
    return some(9)
}

// the Result twins. an owned operand releases the box it unwrapped out of,
// a borrowed one does not, and the error crossing a `?` is a real value
// either way
fn result_owned() -> Result<int, Cell> {
    let c: Cell = made("result")?
    io.println("  result {c.n}")
    return ok(1)
}

fn result_owned_error() -> Result<Cell, Cell> {
    let c: Cell = faulty("error")?
    io.println("  unreachable {c.n}")
    return ok(c)
}

fn result_borrowed_local() -> Result<Cell, Cell> {
    let held: Result<Cell, Cell> = faulty("borrowed")
    let c: Cell = held?
    io.println("  unreachable {c.n}")
    return ok(c)
}

fn result_borrowed_parameter(held: Result<Cell, Cell>) -> Result<Cell, Cell> {
    let c: Cell = held?
    io.println("  unreachable {c.n}")
    return ok(c)
}

fn show(tag: string, value: Option<int>) {
    match value {
        some(n) => { io.println("{tag} {n}") }
        none => { io.println("{tag} none") }
    }
}

fn show_result(tag: string, value: Result<Cell, Cell>) {
    match value {
        ok(c) => { io.println("{tag} ok {c.n}") }
        err(e) => { io.println("{tag} err {e.n}") }
    }
}

fn main() {
    by_match()
    show("owned", owned_dropped())
    match owned_returned() {
        some(c) => { io.println("returned out {c.n}") }
        none => { io.println("returned out none") }
    }
    show("local", borrowed_local())
    show("parameter", borrowed_parameter(fresh("parameter")))
    show("field", borrowed_field())
    show("struct", owned_struct())
    show("read", read_through())
    show("write", write_through())
    show("argument", argument())
    show("loop", looped())
    match result_owned() {
        ok(n) => { io.println("result ok {n}") }
        err(e) => { io.println("result err {e.n}") }
    }
    show_result("owned error", result_owned_error())
    show_result("borrowed local", result_borrowed_local())
    show_result("borrowed parameter",
                result_borrowed_parameter(faulty("parameter error")))
    io.println("end")
}
