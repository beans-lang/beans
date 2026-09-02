// What a Map looks like after a contained panic inside remove().
//
// remove() releases the entry's value, and for a class value that runs user
// deinit code. Contained by brew/join, a panic there unwinds out of the
// runtime frame, so the entry has to be unlinked *before* the release runs —
// the rule beans_map_set already states for its own hit path (issue #44).
// Releasing first left the native backend reporting the key still present,
// holding a value whose deinit had already run, while the interpreter
// reported it gone: one checked program, two answers (issue #79).
//
// Three storage shapes reach three different unlink paths: a plain Map
// swap-removes, an OrderedMap leaves a stable hole, and a wide value lives in
// the parallel buffer the unlink overwrites. All three are past the
// linear-scan cutoff so the hash index, not the linear scan, does the work.
import std.io

// Only the key being removed is loud. A map full of panicking deinits would
// panic again while the unwind released the rest, and that is the documented
// double-panic abort — it would say nothing about the entry's state.
class Loud {
    pub name: string
    pub loud: bool
    fn init(name: string, loud: bool) {
        self.name = name
        self.loud = loud
    }
    fn deinit() {
        if self.loud {
            io.println("  deinit {self.name} panics")
            let empty: List<int> = []
            let unused: int = empty[0]
        }
    }
}

struct Boxed {
    held: Loud
    n: int
}

class Plain {
    pub items: Map<int, Loud> = {}
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items[i] = new Loud("plain-{i}", i == 5)
            i += 1
        }
    }
    pub fn drop_one(key: int) -> bool { return self.items.remove(key) }
}

class Ordered {
    pub items: OrderedMap<int, Loud> = {}
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items[i] = new Loud("ordered-{i}", i == 5)
            i += 1
        }
    }
    pub fn drop_one(key: int) -> bool { return self.items.remove(key) }
}

class Wide {
    pub items: Map<int, Boxed> = {}
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items[i] = Boxed { held: new Loud("wide-{i}", i == 5), n: i }
            i += 1
        }
    }
    pub fn drop_one(key: int) -> bool { return self.items.remove(key) }
}

fn report(label: string, len: int, has: bool) {
    io.println("{label} len={len} has={has}")
}

fn main() {
    let plain: Plain = new Plain()
    plain.fill(12)
    let a: Brew<bool> = brew plain.drop_one(5)
    match a.join() {
        ok(v) => { io.println("plain removed {v}") }
        err(problem) => { io.println("plain contained: {problem.kind}") }
    }
    report("plain", plain.items.len(), plain.items.contains_key(5))
    match plain.items.get(5) {
        some(v) => { io.println("plain get = {v.name}") }
        none => { io.println("plain get = none") }
    }

    let ordered: Ordered = new Ordered()
    ordered.fill(12)
    let b: Brew<bool> = brew ordered.drop_one(5)
    match b.join() {
        ok(v) => { io.println("ordered removed {v}") }
        err(problem) => { io.println("ordered contained: {problem.kind}") }
    }
    report("ordered", ordered.items.len(), ordered.items.contains_key(5))
    var order: string = ""
    for key: int, value: Loud in ordered.items {
        order = "{order}{key},"
    }
    io.println("ordered walk {order}")

    let wide: Wide = new Wide()
    wide.fill(12)
    let c: Brew<bool> = brew wide.drop_one(5)
    match c.join() {
        ok(v) => { io.println("wide removed {v}") }
        err(problem) => { io.println("wide contained: {problem.kind}") }
    }
    report("wide", wide.items.len(), wide.items.contains_key(5))
    var total: int = 0
    for key: int, value: Boxed in wide.items {
        total += value.n
    }
    io.println("wide total {total}")
    io.println("still running")
}
