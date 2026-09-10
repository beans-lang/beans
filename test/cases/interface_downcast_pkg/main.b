// The other half of the cross-package downcast: the test is written both in
// the package that owns the interface (lib.probe) and in the one that does
// not, because the emitter reaches the declaration by a different name from
// each (#195).
package main
import std.io
import app.lib

// a class in THIS package implementing an interface from the other one
pub class Local implements lib.Mid {
    pub fn init() {}
    pub fn r() -> int { return 4 }
    pub fn m() -> int { return 5 }
}
// and one reaching it through a base declared over there
pub class SubDeep extends lib.Deep {
    pub fn init() { super.init() }
}

fn report(what: string, got: bool, want: bool) {
    if got == want { io.println("ok   {what} = {got}") }
    else { io.println("BAD  {what} = {got}, want {want}") }
}

fn main() {
    let d: lib.Root = new lib.Deep()
    let s: lib.Root = new lib.Shallow()
    let l: lib.Root = new Local()
    let sd: lib.Root = new SubDeep()

    // tested from the package that owns the interface
    report("lib.probe(Deep)", lib.probe(d), true)
    report("lib.probe(Shallow)", lib.probe(s), false)
    report("lib.probe(Local)", lib.probe(l), true)
    report("lib.probe(SubDeep)", lib.probe(sd), true)

    // and from the package that does not
    var a: bool = false
    match d as? lib.Mid { some(_) => { a = true } none => {} }
    report("main: Deep as? lib.Mid", a, true)
    var b: bool = false
    match s as? lib.Mid { some(_) => { b = true } none => {} }
    report("main: Shallow as? lib.Mid", b, false)
    var c: bool = false
    match l as? lib.Mid { some(_) => { c = true } none => {} }
    report("main: Local as? lib.Mid", c, true)
    var e: bool = false
    match sd as? lib.Mid { some(_) => { e = true } none => {} }
    report("main: SubDeep as? lib.Mid", e, true)
}
