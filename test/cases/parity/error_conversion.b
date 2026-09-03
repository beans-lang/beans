// #46: `?` may cross an error boundary three ways, and both backends have to
// take the same one and do the same amount of work. Before the fix a custom
// error could not leave the function that produced it; the checker accepted a
// bare `f()?` with a foreign error and then the interpreter propagated the
// wrong type while the native backend failed in the emitter.
//
// The `arc+tag` / `arc-tag` markers are the point of this file living in the
// parity gate rather than a golden: comparing printed answers cannot see the
// source error converted twice, or leaked, or released twice. It carries one
// tag per source error, so construct and drop counts are in the compared
// output and the conversion is proven to run exactly once on each backend.
package main

import std.io

// The builtin `Error` is what `to_error` answers; it carries no marker, so the
// counted lifetimes below are only the source errors.

// Case 3: an error with `fn to_error() -> Error`. `?` calls it on the error
// and propagates what comes back. `db` must be built once and dropped once.
class DbError {
    priv detail: string
    fn init(detail: string) {
        self.detail = detail
        io.println("arc+db")
    }
    fn deinit() { io.println("arc-db") }
    fn to_error() -> Error {
        return new Error("db: {self.detail}", "db")
    }
}

// Case 2: a subtype of the caller's error. The reference widens, no code runs,
// nothing is lost — the same object read as the wider type. `disk` is built
// once and dropped once, at the far end where the widened error dies.
interface AppError {
    fn slug() -> string
}

class DiskError implements AppError {
    priv where: string
    fn init(where: string) {
        self.where = where
        io.println("arc+disk")
    }
    fn deinit() { io.println("arc-disk") }
    pub fn slug() -> string { return "disk:{self.where}" }
}

fn db_query() -> Result<int, DbError> {
    return err(new DbError("refused"))
}

// A `?` on a foreign error inside a plain Result<int> function: the acceptance
// shape. Converts through to_error.
fn db_service() -> Result<int> {
    let rows: int = db_query()?
    return ok(rows)
}

fn disk_query() -> Result<int, DiskError> {
    return err(new DiskError("sector0"))
}

// A `?` widening a subtype into the interface the function returns.
fn disk_service() -> Result<int, AppError> {
    let rows: int = disk_query()?
    return ok(rows)
}

fn good_query() -> Result<int, DbError> {
    return ok(10)
}

// The ok path through a converting `?`: the bridge child is never evaluated,
// no source error is built, the value flows straight through.
fn good_service() -> Result<int> {
    let n: int = good_query()?
    return ok(n + 1)
}

// The same conversion with the operand a local read, not a call: the bridge
// hangs off the `?`, so where the Result came from must not matter.
fn local_service() -> Result<int> {
    let r: Result<int, DbError> = err(new DbError("stale"))
    let n: int = r?
    return ok(n)
}

// The issue's own shape: a bare `f()?` in statement position. Nothing pushes
// an expectation at the `?`, and the conversion must run regardless.
fn ping() -> Result<int, DbError> {
    return err(new DbError("timeout"))
}

fn ping_service() -> Result<int> {
    ping()?
    return ok(1)
}

// `??` on a nested Result: each `?` negotiates its own boundary, so a
// convertible error two layers in converts too. One hop errs at the outer
// layer, the other at the inner; each source error is built and dropped
// exactly once and only its own to_error runs.
class OuterHop {
    fn init() { io.println("arc+outer") }
    fn deinit() { io.println("arc-outer") }
    fn to_error() -> Error {
        return new Error("outer refused", "outer")
    }
}

class InnerHop {
    fn init() { io.println("arc+inner") }
    fn deinit() { io.println("arc-inner") }
    fn to_error() -> Error {
        return new Error("inner refused", "inner")
    }
}

fn hop_outer() -> Result<Result<int, InnerHop>, OuterHop> {
    return err(new OuterHop())
}

fn hop_inner() -> Result<Result<int, InnerHop>, OuterHop> {
    return ok(err(new InnerHop()))
}

fn hop_outer_service() -> Result<int> {
    let n: int = hop_outer()??
    return ok(n)
}

fn hop_inner_service() -> Result<int> {
    let n: int = hop_inner()??
    return ok(n)
}

fn main() {
    match db_service() {
        ok(n) => { io.println("db ok {n}") }
        err(e) => { io.println("db err {e.msg} / {e.kind}") }
    }
    match disk_service() {
        ok(n) => { io.println("disk ok {n}") }
        err(e) => { io.println("disk err {e.slug()}") }
    }
    match good_service() {
        ok(n) => { io.println("good ok {n}") }
        err(e) => { io.println("good err {e.kind}") }
    }
    match local_service() {
        ok(n) => { io.println("local ok {n}") }
        err(e) => { io.println("local err {e.msg} / {e.kind}") }
    }
    match ping_service() {
        ok(n) => { io.println("ping ok {n}") }
        err(e) => { io.println("ping err {e.msg} / {e.kind}") }
    }
    match hop_outer_service() {
        ok(n) => { io.println("hop-outer ok {n}") }
        err(e) => { io.println("hop-outer err {e.msg} / {e.kind}") }
    }
    match hop_inner_service() {
        ok(n) => { io.println("hop-inner ok {n}") }
        err(e) => { io.println("hop-inner err {e.msg} / {e.kind}") }
    }
}
