// #155: a `move` hands the value over where it is written, so the value dies
// with whatever took it — and for a `move` parameter that is the callee's own
// frame exit, not the caller's.
//
// The tree interpreter used to leave the spent binding pointing at the value.
// A tree value's lifetime is the host's, so the leftover slot was a second
// owner: the `deinit` ran when the CALLER's binding was overwritten or its
// frame exited, while a native build ran it at the callee's return. One
// checked program, two orders.
//
// The markers balanced on both sides, so the construct/release count this
// gate pins saw nothing at all — only the ordered diff does. That is why
// every section below prints a line between the call and what follows it:
// without that line the two orders are the same bytes.
//
// The rule is not about `unique` and not only about parameters, so this case
// is neither. `unique` was incidental to how the issue was found — a plain
// class diverged identically — and so did `let taken = move held` in a nested
// block with no call in sight. Every `move` in the language is one HIR node,
// so a struct literal, a list literal, `some(...)`, a map store, a method, a
// static, an interface implementation and a discard parameter all reached it.
//
// The controls carry as much weight as the divergent shapes:
//
//   * a temporary passed straight into the same `move` parameter always
//     agreed, because the caller had no slot to leave behind. Same parameter,
//     same signature, two lifetimes decided by how the caller happened to
//     produce the argument — which is what proved the interpreter was
//     contradicting itself rather than following its own rule;
//   * a borrowed parameter owns nothing, and its argument must go on dying at
//     the caller's scope exit;
//   * a value the callee moves onward — into a field, into a further call,
//     out through `return` — must NOT die at that callee's exit.
//
// Order is the whole point, so the sections that carry several owned values
// are wide on purpose: three moved-in parameters, not one, because reverse
// parameter order is invisible at n = 1, and a full frame teardown with block
// locals, two defers, two function locals, a borrowed parameter and two moved
// -in parameters, because that is the only place all four steps of the exit
// order can be told apart.
package main

import std.io

class Loud {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    pub fn tag_of() -> string { return self.tag }
}

// the same rule through a move-only handle: `unique` changes who may hold the
// reference, never when the reference dies
unique class Once {
    priv tag: string

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }

    pub fn tag_of() -> string { return self.tag }
}

struct Crate {
    held: Loud
    count: int
}

class Depot {
    pub stored: Option<Loud> = none
}

interface Taker {
    fn absorb(move p: Loud)
}

class RealTaker implements Taker {
    pub fn absorb(move p: Loud) {
        io.println("  iface body {p.tag_of()}")
    }
}

class Sink {
    pub fn eat(move p: Loud) {
        io.println("  method body {p.tag_of()}")
    }

    pub static fn swallow(move p: Loud) {
        io.println("  static body {p.tag_of()}")
    }
}

// (a) never touched, (b) read: the value is the callee's either way
fn untouched(move p: Loud) {
    io.println("  untouched body")
}

fn reads(move p: Loud) {
    io.println("  reads body {p.tag_of()}")
}

fn untouched_unique(move p: Once) {
    io.println("  unique body")
}

// (c) moved out again into a local of the callee: the local is the owner now,
// and it is still the callee's frame that ends the value
fn to_local(move p: Loud) {
    let held: Loud = move p
    io.println("  to_local body {held.tag_of()}")
}

// (d) forwarded to a further call: the value belongs to `inner`, so it dies at
// inner's return and the rest of the outer body runs after that
fn inner(move q: Loud) {
    io.println("  inner body {q.tag_of()}")
}

fn forwards(move p: Loud) {
    io.println("  forwards before")
    inner(move p)
    io.println("  forwards after")
}

// (e) stored into a field, (f) returned: moved onward, so the callee's exit
// must NOT be where it dies
fn stores(move p: Loud, into: Depot) {
    into.stored = some(move p)
    io.println("  stores body")
}

fn returns(move p: Loud) -> Loud {
    io.println("  returns body")
    return move p
}

// (g) dropped on an early return, and on the full path, from one function
fn early(move p: Loud, stop: bool) {
    if stop {
        io.println("  early return")
        return
    }
    io.println("  full path {p.tag_of()}")
}

// (i) several moved-in parameters: reverse declaration order, and one of them
// handed on so the other two still go in that order around it
fn three(move a: Loud, move b: Loud, move c: Loud) {
    io.println("  three body {a.tag_of()} {b.tag_of()} {c.tag_of()}")
}

fn three_with_a_handoff(move a: Loud, move b: Loud, move c: Loud) {
    io.println("  handoff before")
    inner(move b)
    io.println("  handoff after")
}

// a discard `move _` owns what it takes exactly as a named parameter does, and
// two of them in one list must not share a slot
fn discards(move _: Loud, move keep: Loud, move _: Loud) {
    io.println("  discards body {keep.tag_of()}")
}

// the whole exit order in one frame: block locals innermost first, then the
// defers newest first, then the function's own locals newest first, then the
// moved-in parameters last-declared first. The borrowed parameter owns
// nothing and must not appear at all.
fn full_order(move p1: Loud, lent: Loud, move p2: Loud) {
    let first: Loud = new Loud("order-local-1")
    defer io.println("  defer 1")
    let second: Loud = new Loud("order-local-2")
    defer io.println("  defer 2")
    if true {
        let nested: Loud = new Loud("order-block")
        io.println("  order body {p1.tag_of()} {lent.tag_of()} {p2.tag_of()} {first.tag_of()} {second.tag_of()} {nested.tag_of()}")
    }
    io.println("  order tail")
}

// the control: a borrowed parameter owns nothing, so its argument outlives the
// call under the caller's own scope
fn borrows(p: Loud) {
    io.println("  borrows body {p.tag_of()}")
}

// a fresh result, so the temporary control has a call to come from as well as
// an inline `new`
fn make(tag: string) -> Loud {
    return new Loud(tag)
}

fn main() {
    io.println("-- one moved-in parameter, plain class")
    var a: Loud = new Loud("a")
    untouched(move a)
    io.println("after untouched")

    var b: Loud = new Loud("b")
    reads(move b)
    io.println("after reads")

    io.println("-- one moved-in parameter, unique class")
    var u: Once = new Once("u")
    untouched_unique(move u)
    io.println("after unique")

    io.println("-- control: a temporary is the same parameter")
    untouched(make("temp-call"))
    io.println("after temp from a call")
    untouched(new Loud("temp-new"))
    io.println("after temp from new")

    io.println("-- control: a borrowed parameter owns nothing")
    let lent: Loud = new Loud("lent")
    borrows(lent)
    io.println("after borrows")

    io.println("-- moved to a local of the callee")
    var c: Loud = new Loud("c")
    to_local(move c)
    io.println("after to_local")

    io.println("-- forwarded to a further call")
    var d: Loud = new Loud("d")
    forwards(move d)
    io.println("after forwards")

    io.println("-- moved onward: into a field, and out through return")
    let depot: Depot = new Depot()
    var e: Loud = new Loud("e")
    stores(move e, depot)
    io.println("after stores")
    var f: Loud = new Loud("f")
    let back: Loud = returns(move f)
    io.println("after returns {back.tag_of()}")

    io.println("-- early return and the full path")
    var g: Loud = new Loud("g")
    early(move g, true)
    io.println("after early")
    var h: Loud = new Loud("h")
    early(move h, false)
    io.println("after full")

    io.println("-- three moved-in parameters")
    var x1: Loud = new Loud("x1")
    var x2: Loud = new Loud("x2")
    var x3: Loud = new Loud("x3")
    three(move x1, move x2, move x3)
    io.println("after three")

    var y1: Loud = new Loud("y1")
    var y2: Loud = new Loud("y2")
    var y3: Loud = new Loud("y3")
    three_with_a_handoff(move y1, move y2, move y3)
    io.println("after handoff")

    io.println("-- two discards and a name in one parameter list")
    var z1: Loud = new Loud("z1")
    var z2: Loud = new Loud("z2")
    var z3: Loud = new Loud("z3")
    discards(move z1, move z2, move z3)
    io.println("after discards")

    io.println("-- the whole exit order")
    var o1: Loud = new Loud("order-param-1")
    let o2: Loud = new Loud("order-lent")
    var o3: Loud = new Loud("order-param-2")
    full_order(move o1, o2, move o3)
    io.println("after order")

    io.println("-- a method, a static, and an interface implementation")
    let sink: Sink = new Sink()
    var m1: Loud = new Loud("m1")
    sink.eat(move m1)
    io.println("after method")
    var m2: Loud = new Loud("m2")
    Sink.swallow(move m2)
    io.println("after static")
    let taker: Taker = new RealTaker()
    var m3: Loud = new Loud("m3")
    taker.absorb(move m3)
    io.println("after interface")

    io.println("-- a move with no call in it at all")
    var n1: Loud = new Loud("n1")
    if true {
        let taken: Loud = move n1
        io.println("  nested block holds {taken.tag_of()}")
    }
    io.println("after nested block")

    io.println("-- every composite a move can land in")
    var s1: Loud = new Loud("s1")
    if true {
        let crate: Crate = Crate { held: move s1, count: 2 }
        io.println("  crate holds {crate.held.tag_of()} {crate.count}")
    }
    io.println("after struct literal")
    var s2: Loud = new Loud("s2")
    if true {
        let batch: List<Loud> = [move s2]
        io.println("  list holds {batch.len()}")
    }
    io.println("after list literal")
    var s3: Loud = new Loud("s3")
    if true {
        let wrapped: Option<Loud> = some(move s3)
        io.println("  option holds {wrapped.is_some()}")
    }
    io.println("after option")
    var s4: Loud = new Loud("s4")
    if true {
        var table: Map<string, Loud> = {}
        table["k"] = move s4
        io.println("  map holds {table.len()}")
    }
    io.println("after map store")

    io.println("-- a var reinitialised after it was spent")
    var r: Loud = new Loud("r-first")
    untouched(move r)
    io.println("after the first move")
    r = new Loud("r-second")
    io.println("after the reinit")
    untouched(move r)
    io.println("after the second move")

    io.println("-- a loop body, so the drop point repeats")
    for index: int in 0..3 {
        var each: Loud = new Loud("loop-{index}")
        untouched(move each)
        io.println("  iteration {index} tail")
    }
    io.println("after loop")

    io.println("-- what main still owns")
}
