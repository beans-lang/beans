// #124, the lone-handle half: a Brew result a program claims through join()
// belongs to whoever claimed it, and a result nobody claimed dies inside the
// synthesized scope join -- not later, with the handle.
//
// Native has always done both: beans_brew_value reads h->value and zeroes the
// slot, so an explicit join hands ownership to the arm; beans_brew_scope_join
// calls brew_drop_result, so an unclaimed result dies at the join, before the
// scope releases anything else. The tree interpreter handed out a copy and left
// the row's reference in place, so a joined value outlived its match arm and an
// unclaimed one outlived the join -- both dying only when the handle did.
//
// Every case here puts a second loud object AFTER the brew, so the moments are
// told apart: a value that dies at the join prints before that object, a value
// that dies with the handle prints after it. With one loud object and nothing
// between the moments the two orders coincide, which is why nothing caught it.
import std.io

class Loud {
    tag: string = ""
    pub fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

fn make(tag: string) -> Loud { return new Loud(tag) }
fn boom(tag: string) -> Loud { panic("boom {tag}") }

// join() moves the value out: it dies at the end of the match that claimed
// it, before "mid" and before the later local.
fn joined() {
    io.println("-- join --")
    let h: Brew<Loud> = brew make("j.h")
    match h.join() {
        ok(v) => { io.println("joined {v.tag}") }
        err(e) => { io.println("failed") }
    }
    io.println("mid")
    let after: Loud = new Loud("j.after")
    io.println("end")
}

// Two handles, one joined and one left to the scope join. The joined value
// dies at its arm; the unjoined one dies in the synthesized join, which runs
// as a defer -- so before the scope's own locals, newest-first.
fn joined_and_left() {
    io.println("-- one joined one left --")
    let a: Brew<Loud> = brew make("p.a")
    let b: Brew<Loud> = brew make("p.b")
    match a.join() {
        ok(v) => { io.println("joined {v.tag}") }
        err(e) => { io.println("failed") }
    }
    io.println("mid")
    let after: Loud = new Loud("p.after")
    io.println("end")
}

// Nobody joins: every result dies in its own scope join, ahead of the
// scope's locals. One handle, then two, then three -- a rule that only
// holds for one unclaimed result is not the rule. (The handles are spelled
// out rather than looped because a brew inside a nested block is refused;
// TaskGroup is the shape for a fiber per iteration.)
fn left1() {
    io.println("-- unclaimed n=1 --")
    let before: Loud = new Loud("u1.before")
    let a: Brew<Loud> = brew make("u1.a")
    let after: Loud = new Loud("u1.after")
    io.println("built")
}

fn left2() {
    io.println("-- unclaimed n=2 --")
    let before: Loud = new Loud("u2.before")
    let a: Brew<Loud> = brew make("u2.a")
    let b: Brew<Loud> = brew make("u2.b")
    let after: Loud = new Loud("u2.after")
    io.println("built")
}

fn left3() {
    io.println("-- unclaimed n=3 --")
    let before: Loud = new Loud("u3.before")
    let a: Brew<Loud> = brew make("u3.a")
    let b: Brew<Loud> = brew make("u3.b")
    let c: Brew<Loud> = brew make("u3.c")
    let after: Loud = new Loud("u3.after")
    io.println("built")
}

// A claim the program keeps outlives the arm: assigning the arm's binding
// into an outer var retains the value, so it dies with that var. The move
// out of the row must not end its life while the program still holds one.
fn kept() {
    io.println("-- kept --")
    let h: Brew<Loud> = brew make("k.h")
    var held: Option<Loud> = none
    match h.join() {
        ok(v) => { held = some(v) }
        err(e) => {}
    }
    io.println("mid")
    match held {
        some(v) => { io.println("still have {v.tag}") }
        none => { io.println("lost it") }
    }
    let after: Loud = new Loud("k.after")
    io.println("end")
}

// A joined handle carries nothing into its scope join, so joining twice is
// still the closed-handle error and no value is dropped a second time.
fn twice() {
    io.println("-- join twice --")
    let h: Brew<Loud> = brew make("d.h")
    match h.join() {
        ok(v) => { io.println("joined {v.tag}") }
        err(e) => { io.println("failed") }
    }
    match h.join() {
        ok(v) => { io.println("joined again {v.tag}") }
        err(e) => { io.println("second: {e.msg}") }
    }
    io.println("mid")
    let after: Loud = new Loud("d.after")
    io.println("end")
}

// A child that panicked carries no value; the sibling that succeeded still
// dies in its own scope join.
fn failed() {
    io.println("-- join err --")
    let a: Brew<Loud> = brew boom("f.a")
    let b: Brew<Loud> = brew make("f.b")
    match a.join() {
        ok(v) => { io.println("joined {v.tag}") }
        err(e) => { io.println("failed") }
    }
    io.println("mid")
    let after: Loud = new Loud("f.after")
    io.println("end")
}

fn main() {
    joined()
    joined_and_left()
    left1()
    left2()
    left3()
    kept()
    twice()
    failed()
}
