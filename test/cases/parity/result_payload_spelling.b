// A type's identity is not how it is spelled. `f64` and `float`, `i64` and
// `int`, `byte` and `u8` are one type each, and HIR carries both spellings:
// an annotation keeps what was written, a MIR local carries the canonical
// name. Six places in the LLVM emitter asked `render_hir_type(a) ==
// render_hir_type(b)` — a *diagnostic* rendering — and so read one type as
// two. The checker accepted every program below and the native backend then
// refused it at build time talking about the emitter, which is the failure
// shape rule 4 exists to prevent.
//
// The interpreter never compared spellings, so only the native leg was ever
// wrong; the markers are here because this gate counts work as well as
// answers, and a conversion that runs twice is invisible to a diff.
package main

import std.io

class Boom {
    priv why: string
    fn init(why: string) {
        self.why = why
        io.println("arc+boom")
    }
    fn deinit() { io.println("arc-boom") }
    fn to_error() -> Error { return new Error("boom: {self.why}", "boom") }
}

fn pi() -> f64 { return 3.5 }
fn count() -> i64 { return 7 }
fn tag() -> byte { return 9 }

// The repro: the payload is a local read, so MIR gives it the canonical
// spelling while the Result's argument keeps the written one.
fn float_local() -> Result<f64, Boom> {
    let v: f64 = pi()
    return ok(v)
}

fn int_local() -> Result<i64, Boom> {
    let v: i64 = count()
    return ok(v)
}

fn byte_local() -> Result<byte, Boom> {
    let v: byte = tag()
    return ok(v)
}

// The same payloads reached through `?`, which compares the source Result
// against this function's own.
fn float_hop() -> Result<f64, Boom> {
    let v: f64 = float_local()?
    return ok(v)
}

fn int_hop() -> Result<i64, Boom> {
    let v: i64 = int_local()?
    return ok(v)
}

// The error path of the same shape.
fn float_fails() -> Result<f64, Boom> {
    return err(new Boom("no float"))
}

fn float_fails_hop() -> Result<f64, Boom> {
    let v: f64 = float_fails()?
    return ok(v)
}

// A converting `?` out of an aliased payload: crosses Boom into Error.
fn float_service() -> Result<f64> {
    let v: f64 = float_fails()?
    return ok(v)
}

// Generic unification binds a parameter to a concrete type and then checks a
// second use against the binding. Two spellings of one type must bind once.
fn pair<T>(a: T, b: T) -> T { return b }

fn main() {
    io.println("float local {float_local().or(0.0)}")
    io.println("int local {int_local().or(0)}")
    io.println("byte local {byte_local().or(0)}")
    io.println("float hop {float_hop().or(0.0)}")
    io.println("int hop {int_hop().or(0)}")

    match float_fails_hop() {
        ok(v) => { io.println("unexpected ok {v}") }
        err(e) => { io.println("hop err") }
    }
    match float_service() {
        ok(v) => { io.println("unexpected ok {v}") }
        err(e) => { io.println("service err {e.msg} / {e.kind}") }
    }

    let v: f64 = pi()
    io.println("pair float {pair<f64>(v, 1.5)}")
    let n: i64 = count()
    io.println("pair int {pair<i64>(n, 2)}")
}
