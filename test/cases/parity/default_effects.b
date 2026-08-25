// The regression this file exists for: the fix that made a struct default
// run on a referenced-but-not-yet-checked declaration was written twice, in
// the checker and again in the interpreter. Both then ran every default
// twice. The printed field values were identical either way, so comparing
// answers between the backends saw nothing at all — the only trace was an
// extra construct and an extra release per field.
//
// So the markers are the test. `+tag` on construct, `-tag` on release, and
// the gate counts them.
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

fn loud(tag: string) -> Loud { return new Loud(tag) }

struct Pair {
    first: Loud = loud("first")
    second: Loud = loud("second")
}

fn main() {
    // one field given, one defaulted: the default for `first` is built and
    // then released when the explicit value takes its place
    let filled: Pair = Pair { first: loud("explicit") }
    io.println("filled {filled.first.tag_of()} {filled.second.tag_of()}")

    // no fields given: both defaults stand
    let bare: Pair = Pair {}
    io.println("bare {bare.first.tag_of()} {bare.second.tag_of()}")
}
