// Two rules the emitter's type comparison has to keep apart, in one file.
//
// `f64` and `float` are one type spelled two ways, so a `?` between them
// must pass the box straight through. `Result<int>` and `Result<int, Error>`
// are one type to the *checker* — the defaulted error is `Error` — but the
// `?` lowering builds a fresh error box for the second, so the emitter must
// not treat them as one representation. hir_types_equal says they are;
// hir_types_identical, which the emitter uses, says they are not.
package main

import std.io

fn alias_source() -> Result<float, Error> { return ok(2.5) }

// Same representation: the payload differs only in spelling.
pub fn alias_hop() -> Result<f64, Error> {
    let value: f64 = alias_source()?
    return ok(value + 1.0)
}

fn defaulted_source() -> Result<int, Error> { return err(new Error("no", "k")) }

// Same type, different spelling of the error arm.
pub fn defaulted_hop() -> Result<int> {
    let value: int = defaulted_source()?
    return ok(value + 1)
}

fn main() {
    io.println("alias {alias_hop().or(0.0)}")
    match defaulted_hop() {
        ok(value) => { io.println("unexpected {value}") }
        err(why) => { io.println("defaulted {why.kind}") }
    }
}
