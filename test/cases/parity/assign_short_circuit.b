// A `?` in an assignment target short-circuits the whole statement, the way
// it does in every other position. The interpreter answered `next()` for a
// propagating target instead of returning it: the error was thrown away and
// the rest of the function ran on, while the native backend had already
// left. Both legs print the same trace here, so a swallow shows up as extra
// lines on one side.
//
// The `?` here is over a Result, not an Option, and that is not incidental:
// a reference `?` unwraps out of an *Option* is never released by the native
// backend (beans-lang/beans#110), which is a fault in the unwrap rather than
// in the target and would make every marker below imbalanced for a reason
// this case is not about. With Result the markers pin the other half of the
// claim — that a short-circuited statement leaves nothing behind.
package main

import std.io

struct Pair {
    a: int
    b: int
}

class Cell {
    pub n: int = 0
    pub p: Pair = Pair { a: 0, b: 0 }
    pub xs: List<int> = [0, 0]
    pub m: Map<string, int> = {}
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }
}

class Missing {
    pub why: string

    fn init(why: string) { self.why = why }
}

fn maybe(hit: bool, cell: Cell, tag: string) -> Result<Cell, Missing> {
    if hit { return ok(cell) }
    io.println("  miss {tag}")
    return err(new Missing(tag))
}

fn maybe_key(hit: bool) -> Result<string, Missing> {
    if hit { return ok("k") }
    io.println("  miss key")
    return err(new Missing("key"))
}

fn traced(tag: string, n: int) -> int {
    io.println("  value {tag}")
    return n
}

// a class field target
fn field_target(hit: bool, cell: Cell) -> Result<Cell, Missing> {
    maybe(hit, cell, "field")?.n = traced("field", 3)
    io.println("  after field")
    return err(new Missing("field"))
}

// a record place inside that object: two hops past the `?`
fn record_target(hit: bool, cell: Cell) -> Result<Cell, Missing> {
    maybe(hit, cell, "record")?.p.a = traced("record", 4)
    io.println("  after record")
    return err(new Missing("record"))
}

// an element target, whose receiver is a field read past the `?`
fn index_target(hit: bool, cell: Cell) -> Result<Cell, Missing> {
    maybe(hit, cell, "index")?.xs[0] = traced("index", 5)
    io.println("  after index")
    return err(new Missing("index"))
}

// the key of an element target: it evaluates after the receiver and before
// the value, so a `?` in it leaves before the value runs
fn key_target(hit: bool, cell: Cell) -> Result<string, Missing> {
    cell.m[maybe_key(hit)?] = traced("key", 6)
    io.println("  after key")
    return err(new Missing("key"))
}

fn main() {
    for hit: bool in [true, false] {
        io.println("hit {hit}")
        let cell: Cell = new Cell("cell{hit}")
        field_target(hit, cell)
        record_target(hit, cell)
        index_target(hit, cell)
        key_target(hit, cell)
        io.println("  state {cell.n} {cell.p.a} {cell.xs[0]} {cell.m.len()}")
    }
    io.println("end")
}
