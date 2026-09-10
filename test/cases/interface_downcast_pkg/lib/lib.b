// The interface an `as?` tests for lives in one package and the classes that
// reach it are spread across two (#195). The native test is a table filled
// from the emitter's own conformance walk, so a relation written across a
// package boundary is the shape that walk could most easily miss: a class
// here implementing the interface, a class in the other package implementing
// it, and a class in the other package reaching it through a base declared
// in this one.
package lib

pub interface Root { fn r() -> int }
pub interface Mid extends Root { fn m() -> int }

pub class Deep implements Mid {
    pub fn init() {}
    pub fn r() -> int { return 1 }
    pub fn m() -> int { return 2 }
}
pub class Shallow implements Root {
    pub fn init() {}
    pub fn r() -> int { return 3 }
}
pub fn probe(v: Root) -> bool {
    match v as? Mid { some(_) => { return true } none => { return false } }
}
