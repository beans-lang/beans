// What a catch frame does NOT catch (issue #145, spec/CONCURRENCY.md).
//
// The frame is the call, so a panic outside the call is outside the frame:
// this program contains one call, catches it, and then fails on its own — and
// that second failure ends the process with the ordinary report and exit 3,
// with its frames abandoned, exactly as a program that never contained
// anything. Argument evaluation is outside too, and the last case proves it:
// the argument panics before the frame is opened.
//
// BEANS_CONTAINED_CASE picks which failure to run, so one program covers both
// without two nearly identical files.
import std.io
import std.os

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("drop {self.tag}") }
}

fn refuses(n: int) -> int {
    panic("refused {n}")
}

fn doubled(n: int) -> int { return n * 2 }

// An uncontained panic abandons its frames: neither the defer nor the local's
// deinit may run, and this is where the golden proves the catch frame did not
// quietly turn every panic in the program into an unwinding one.
fn fails_outside() -> int {
    let held: Res = new Res("outside-held")
    defer io.println("outside defer")
    panic("outside any frame")
}

fn main() {
    let which: string = os.env("BEANS_CONTAINED_CASE").or("after")
    match contained refuses(1) {
        ok(v) => { io.println("unexpected ok {v}") }
        err(p) => { io.println("caught {p.kind}") }
    }
    if which == "argument" {
        // The argument is evaluated before the frame is opened, so its panic
        // is not this call's to catch.
        match contained doubled(refuses(2)) {
            ok(v) => { io.println("unexpected ok {v}") }
            err(p) => { io.println("unexpected catch {p.kind}") }
        }
        io.println("unreachable")
        return
    }
    let ignored: int = fails_outside()
    io.println("unreachable")
}
