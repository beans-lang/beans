// #106: a TaskGroup discards the results nobody claimed in a defined order --
// newest-first, reverse spawn order, the LIFO order a scope drops what it owns.
// The tree interpreter leaves each result on its child row and releases the
// row list back to front, so the discarded values' deinits ran newest-first;
// the native runtime dropped each result inline as it joined the children in
// spawn order, so they ran oldest-first. Both engines now discard newest-first,
// for a whole group dropped at scope exit and for cancel_all, at n = 1, 2 and 4
// so a rule that only holds for two children is caught. No panic anywhere, and
// the group's own delivery order (next, wait_all) is a separate promise this
// does not touch.
import std.io

class Loud {
    tag: string = ""
    pub fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

fn make(tag: string) -> Loud { return new Loud(tag) }
fn boom(tag: string) -> Loud { panic("boom {tag}") }

// Build n children whose results nobody claims, then let the group die at the
// scope exit: the synthesized scope join discards them newest-first.
fn scope_discard(n: int) {
    io.println("-- scope discard n={n} --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    var i: int = 0
    for i < n {
        g.brew(make("s{n}.{i}"))
        i += 1
    }
    io.println("built")
}

// cancel_all discards every outcome, also newest-first.
fn cancel_discard(n: int) {
    io.println("-- cancel discard n={n} --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    var i: int = 0
    for i < n {
        g.brew(make("c{n}.{i}"))
        i += 1
    }
    io.println("built")
    g.cancel_all()
    io.println("cancelled")
}

// wait_all() that fails hands back the first failure and discards the ok
// results nobody took -- also newest-first, skipping the failure row (#106).
fn wait_all_fail() {
    io.println("-- wait_all fail --")
    let g: TaskGroup<Loud> = new TaskGroup<Loud>()
    g.brew(make("w0"))
    g.brew(boom("w1"))
    g.brew(make("w2"))
    g.brew(make("w3"))
    match g.wait_all() {
        ok(vs) => { io.println("unexpected ok") }
        err(e) => { io.println("failed") }
    }
    io.println("waited")
}

fn main() {
    scope_discard(1)
    scope_discard(2)
    scope_discard(4)
    cancel_discard(4)
    wait_all_fail()
}
