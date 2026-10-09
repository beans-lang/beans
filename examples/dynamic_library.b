// Libraries open with `RTLD_LOCAL`; calling a symbol address requires caller-side `unsafe`.
// Set `BEANS_DYLIB_EXAMPLE` to test a library; `test/dylib.sh` builds one for the example.

import std.io
import std.dl
import std.dylib
import std.os

// What a loaded library gives you: symbols, and calls through them.
fn use_library(path: string) -> Result<int> {
    let lib: dylib.Dylib = dylib.Dylib.open(path)?
    io.println("opened the library")

    // Looking up a symbol is safe; calling its address requires `unsafe`.
    let present: bool = lib.has("plug_add")
    let absent: bool = lib.has("plug_nothing_here")
    io.println("has plug_add {present}, has a made-up name {absent}")

    let answer: dylib.Symbol = lib.find("plug_answer")?
    let double: dylib.Symbol = lib.find("plug_double")?
    let add: dylib.Symbol = lib.find("plug_add")?
    let mix: dylib.Symbol = lib.find("plug_mix")?
    io.println("resolved four symbols {!answer.is_null() && !add.is_null()}")

    // Here is the unsafe part, and it looks like it.
    unsafe {
        io.println("no arguments gives {dl.call0(answer.address)}")
        io.println("one argument gives {dl.call1(double.address, 21)}")
        io.println("two arguments give {dl.call2(add.address, 40, 2)}")
        io.println("three arguments give {dl.call3(mix.address, 1, 2, 3)}")
    }

    // Address zero is valid; `find` reports lookup failure through `Result`.
    // `find` reports failure as an `err` rather than by handing back a null address.
    let zero: dylib.Symbol = lib.find("plug_zero")?
    unsafe {
        io.println("a function returning zero returns {dl.call0(zero.address)}")
    }

    match lib.find("plug_definitely_missing") {
        ok(s) => io.println("unexpectedly found a missing symbol"),
        err(e) => io.println("a missing symbol: {e.kind}"),
    }

    // Closing is explicit so the error is visible; deinit would do it silently. Every
    // address from this library is dead afterwards, which is why nothing is called here.
    io.println("closed cleanly {lib.close().or(false)}")
    match lib.find("plug_add") {
        ok(s) => io.println("unexpectedly resolved after closing"),
        err(e) => io.println("finding after close: {e.kind}"),
    }
    return ok(1)
}

// The failures, none of which need a real library.
fn refusals() {
    match dylib.Dylib.open("/definitely/not/a/library.so") {
        ok(lib) => io.println("unexpectedly opened nothing"),
        err(e) => io.println("a missing library: {e.kind}"),
    }
    match dylib.Dylib.open("") {
        ok(lib) => io.println("unexpectedly opened an empty path"),
        err(e) => io.println("an empty path: {e.kind}"),
    }
    // A path that exists but is not a loadable object.
    match dylib.Dylib.open("/etc/hosts") {
        ok(lib) => io.println("unexpectedly loaded a text file"),
        err(e) => io.println("not a library: {e.kind}"),
    }
}

fn main() {
    refusals()
    match os.env("BEANS_DYLIB_EXAMPLE") {
        some(path) => {
            match use_library(path) {
                ok(n) => io.println("library ok"),
                err(e) => io.println("library failed: {e.msg}"),
            }
        }
        none => {
            // No library to load, so the loading half is skipped rather than faked.
            // test/dylib.sh builds one and sets BEANS_DYLIB_EXAMPLE.
            io.println("no library given, so only the failure paths ran")
        }
    }
    io.println("done")
}
