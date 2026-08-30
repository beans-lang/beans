// A deinit that panics while a map replace holds the old value (issue #44,
// spec/CONCURRENCY.md): the store stands. The runtime stores the new value
// and drops the duplicate key before the old value's release — the only
// step that can run user code — so the contained panic finds the map
// already holding the new entry and nothing is double-freed. The declined
// insert releases the incoming value the same way. Reverting the runtime
// order (release-old-first) flips "replace entry" to the old tag; reverting
// the emitter's clear-before hand-off corrupts the heap under
// BEANS_NO_POOL=1.
import std.io

class Loud {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() {
        // "q-" values stay silent so the golden does not depend on when a
        // static map tears down (the backends disagree on that today)
        if self.tag.starts_with("q-") { return }
        io.println("  deinit {self.tag}")
        if self.tag.starts_with("boom") {
            let e: List<int> = []
            let x: int = e[0]
        }
    }
}

class Store {
    pub static cache: Map<string, Loud> = {}
}

fn fresh_key(n: int) -> string { return "key-{n * 100}" }

fn replace_boom() -> int {
    Store.cache[fresh_key(1)] = new Loud("boom-old")
    // same key value, fresh string object: the replace path; the old
    // value's deinit panics after the new value is already stored
    Store.cache[fresh_key(1)] = new Loud("q-new")
    return Store.cache.len()
}

fn decline_boom() -> int {
    var m: Map<string, Loud> = {}
    if !m.insert(fresh_key(2), new Loud("keeper")) { return -1 }
    // declined: the incoming value is released first; its deinit panics
    // while the caller still owns the duplicate key
    if !m.insert(fresh_key(2), new Loud("boom-decline")) { return -2 }
    return m.len()
}

fn run(which: int) -> int {
    if which == 1 { return replace_boom() }
    return decline_boom()
}

fn shield(label: string, which: int) -> string {
    let child: Brew<int> = brew run(which)
    match child.join() {
        ok(v) => { return "{label}: ok {v}" }
        err(p) => { return "{label}: {p.kind}" }
    }
}

fn main() {
    io.println(shield("replace", 1))
    io.println("replace len: {Store.cache.len()}")
    match Store.cache.get(fresh_key(1)) {
        some(v) => { io.println("replace entry: {v.tag}") }
        none => { io.println("replace entry gone") }
    }
    io.println(shield("decline", 2))
}
