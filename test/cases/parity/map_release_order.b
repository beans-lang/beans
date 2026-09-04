// #97: a Map that holds class keys AND class values releases them in a
// different order on the two backends when it is dropped, reassigned or has an
// entry removed. The native runtime walks one entry array and releases each
// entry's value before its own key, entries back to front; the interpreter
// kept keys and values in two fields and released all values and then all keys.
// clear() already agreed (#83); this is the rest of the family.
//
// The interpreter now stores each entry as one value that owns both halves, so
// the host cascade releases them the way the native runtime does, with no
// by-hand release. The two backends must print the same order -- the diff in
// backend_parity.sh is the order check -- and the arc markers balance, so
// nothing leaks and nothing is released twice. n = 1, 2 and 3, because a rule
// that only holds for two entries is exactly what the two-field split hid.
package main

import std.io

class Loud {
    tag: string = ""
    pub fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
}

fn fill(m: Map<Loud, Loud>, prefix: string, n: int) {
    var i: int = 0
    for i < n {
        m[new Loud("{prefix}k{i}")] = new Loud("{prefix}v{i}")
        i += 1
    }
}

// The whole map dies at scope exit: no interpreter hook runs, the host cascade
// releases the entries, and each releases its value before its key.
fn dropped(prefix: string, n: int) {
    io.println("-- dropped {prefix} --")
    var m: Map<Loud, Loud> = {}
    fill(m, prefix, n)
    io.println("full {m.len()}")
}

// A reassignment publishes the new empty map, then the old one dies the same
// way a drop does.
fn reassigned(prefix: string, n: int) {
    io.println("-- reassigned {prefix} --")
    var m: Map<Loud, Loud> = {}
    fill(m, prefix, n)
    m = {}
    io.println("empty {m.len()}")
}

// clear() detaches the entries, publishes an empty map, then releases them.
fn cleared(prefix: string, n: int) {
    io.println("-- cleared {prefix} --")
    var m: Map<Loud, Loud> = {}
    fill(m, prefix, n)
    m.clear()
    io.println("empty {m.len()}")
}

// remove() of a single entry releases that entry's value before its key. A
// fresh key of equal structure finds the stored entry; the temporary is
// released after, so the value and the stored key are the two the remove drops.
fn removed(prefix: string) {
    io.println("-- removed {prefix} --")
    var m: Map<Loud, Loud> = {}
    fill(m, prefix, 3)
    io.println("remove middle")
    m.remove(new Loud("{prefix}k1"))
    io.println("kept {m.len()}")
}

// A map whose value is itself a map: the outer entry releases its value (the
// inner map) before its key, and the inner map in turn releases its entry's
// value before its key.
fn nested(prefix: string) {
    io.println("-- nested {prefix} --")
    var outer: Map<Loud, Map<Loud, Loud>> = {}
    var inner: Map<Loud, Loud> = {}
    inner[new Loud("{prefix}ik")] = new Loud("{prefix}iv")
    outer[new Loud("{prefix}ok")] = move inner
    io.println("built {outer.len()}")
}

fn main() {
    dropped("d1", 1)
    dropped("d2", 2)
    dropped("d3", 3)
    reassigned("r", 2)
    cleared("c", 2)
    removed("x")
    nested("n")
}
