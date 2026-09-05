// #124: a TaskGroup result a program CLAIMS belongs to whoever claimed it.
// next(), try_next() and wait_all() each move the value out of its row, so
// the claimed value dies with the binding that took it -- the end of the
// match arm -- and the group keeps no second reference that would hold it
// alive until the group itself died. The native runtime always did this
// (taskgroup_detach takes the row off the list, beans_brew_value zeroes
// h->value); the tree interpreter handed out a copy and left the row's
// reference in place, so a claimed value outlived its arm by a whole
// function. Both engines print this file byte for byte.
//
// n = 1 hides the bug: the single claim drains the group, which empties
// the row list at that same moment, so the two orders coincide. Every
// shape below is therefore also run at n = 2 and n = 4, with only some of
// the rows claimed, so the rows still held by the group print after the
// claimed ones and the two moments are told apart.
import std.io

class Loud {
    tag: string = ""
    pub fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

fn make(tag: string) -> Loud { return new Loud(tag) }
fn boom(tag: string) -> Loud { panic("boom {tag}") }

// next() claims k of n rows. Each claimed value has to die between
// "claimed" and "arm end"; the n - k rows nobody claimed die at "fn end",
// newest-first, when the group goes.
fn claim(n: int, k: int) {
    io.println("-- next n={n} k={k} --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    var i: int = 0
    for i < n {
        g.brew(make("n{n}.{i}"))
        i += 1
    }
    var c: int = 0
    for c < k {
        match g.next() {
            some(r) => {
                match r {
                    ok(v) => { io.println("claimed {v.tag}") }
                    err(e) => { io.println("claimed err") }
                }
                io.println("arm end")
            }
            none => { io.println("empty") }
        }
        c += 1
    }
    io.println("fn end")
}

// try_next() takes the same path through the claim, so it moves the value
// out the same way. The first delivery uses next() to be sure a child has
// finished; try_next() never parks.
fn claim_try(n: int) {
    io.println("-- try_next n={n} --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    var i: int = 0
    for i < n {
        g.brew(make("t{n}.{i}"))
        i += 1
    }
    match g.next() {
        some(r) => {
            match r {
                ok(v) => { io.println("claimed {v.tag}") }
                err(e) => { io.println("claimed err") }
            }
            io.println("arm end")
        }
        none => { io.println("empty") }
    }
    match g.try_next() {
        some(r) => {
            match r {
                ok(v) => { io.println("try claimed {v.tag}") }
                err(e) => { io.println("try claimed err") }
            }
            io.println("try arm end")
        }
        none => { io.println("try empty") }
    }
    io.println("fn end")
}

// A claim the program keeps: assigning the arm's binding into an outer
// var retains the value, so it survives the arm and dies with that var at
// the function's end. The claim moves the row's reference out; it must not
// end the value's life while the program still holds one.
fn claim_kept(n: int) {
    io.println("-- kept n={n} --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    var i: int = 0
    for i < n {
        g.brew(make("k{n}.{i}"))
        i += 1
    }
    var kept: Option<Loud> = none
    match g.next() {
        some(r) => {
            match r {
                ok(v) => { kept = some(v) }
                err(e) => {}
            }
            io.println("arm end")
        }
        none => { io.println("empty") }
    }
    match kept {
        some(held) => { io.println("still have {held.tag}") }
        none => { io.println("lost it") }
    }
    io.println("fn end")
}

// wait_all() moves every value into the list it answers, the way
// beans_taskgroup_collect does. The list is the only owner from there, so
// the values die when the list does -- after "list end", newest-first.
fn collect(n: int) {
    io.println("-- wait_all n={n} --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    var i: int = 0
    for i < n {
        g.brew(make("w{n}.{i}"))
        i += 1
    }
    match g.wait_all() {
        ok(values) => {
            io.println("got {values.len()}")
            for v: Loud in values { io.println("have {v.tag}") }
            io.println("list end")
        }
        err(e) => { io.println("failed") }
    }
    io.println("fn end")
}

// A row that panicked carries no value, and claiming it must not disturb
// the rows that do. The claimed err arm ends, then the remaining values
// die with the group.
fn claim_err() {
    io.println("-- claim err --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    g.brew(boom("e0"))
    g.brew(make("e1"))
    g.brew(make("e2"))
    match g.next() {
        some(r) => {
            match r {
                ok(v) => { io.println("claimed {v.tag}") }
                err(e) => { io.println("claimed err") }
            }
            io.println("arm end")
        }
        none => { io.println("empty") }
    }
    io.println("fn end")
}

// A drained group is reusable: claiming every row empties the list, and a
// second fleet on the same handle claims the same way.
fn reuse() {
    io.println("-- reuse --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    g.brew(make("r0"))
    g.brew(make("r1"))
    var c: int = 0
    for c < 2 {
        match g.next() {
            some(r) => {
                match r {
                    ok(v) => { io.println("claimed {v.tag}") }
                    err(e) => { io.println("claimed err") }
                }
                io.println("arm end")
            }
            none => { io.println("empty") }
        }
        c += 1
    }
    io.println("drained")
    g.brew(make("r2"))
    g.brew(make("r3"))
    match g.next() {
        some(r) => {
            match r {
                ok(v) => { io.println("claimed {v.tag}") }
                err(e) => { io.println("claimed err") }
            }
            io.println("arm end")
        }
        none => { io.println("empty") }
    }
    io.println("fn end")
}

fn main() {
    claim(1, 1)
    claim(2, 1)
    claim(2, 2)
    claim(4, 1)
    claim(4, 2)
    claim(4, 4)
    claim_try(2)
    claim_try(4)
    claim_kept(2)
    claim_kept(4)
    collect(1)
    collect(2)
    collect(4)
    claim_err()
    reuse()
}
