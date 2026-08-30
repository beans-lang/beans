// A return leaves every scope it sits in, innermost first: the locals of the
// nested blocks drop as their blocks exit, then the function's defers run
// newest-first, then the function's own locals drop. The tree interpreter
// always walked out that way; the native backend ran the defers before any
// local, so a local declared inside an `if` or a loop body had its deinit
// printed on the other side of the defer. Both backends must agree about the
// order, on a plain return, a return from two levels down, a `?` that leaves
// from inside a block, and a return from a match arm. The arc+/arc- markers
// pin that every value is built and released exactly once.
import std.io

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag; io.println("arc+{tag}") }
    fn deinit() { io.println("arc-{self.tag}") }
}

fn from_if(c: bool) -> int {
    let outer: Res = new Res("if-outer")
    defer io.println("defer if")
    if c {
        let inner: Res = new Res("if-inner")
        return 1
    }
    return 0
}

fn from_loop() -> int {
    let outer: Res = new Res("loop-outer")
    defer io.println("defer loop A")
    defer io.println("defer loop B")
    var i: int = 0
    for i < 3 {
        let body: Res = new Res("loop-body-{i}")
        if i == 1 {
            let deep: Res = new Res("loop-deep")
            return i
        }
        i += 1
    }
    return -1
}

fn failing(n: int) -> Result<int> {
    if n > 0 { return err("n too big") }
    return ok(n)
}

fn from_try() -> Result<int> {
    let outer: Res = new Res("try-outer")
    defer io.println("defer try")
    if true {
        let inner: Res = new Res("try-inner")
        let got: int = failing(5)?
        return ok(got)
    }
    return ok(0)
}

fn from_match(o: Option<int>) -> int {
    let outer: Res = new Res("match-outer")
    defer io.println("defer match")
    match o {
        some(v) => {
            let bound: Res = new Res("match-bound")
            return v
        }
        none => { return 0 }
    }
}

fn from_break() -> int {
    let outer: Res = new Res("break-outer")
    defer io.println("defer break")
    var i: int = 0
    var seen: int = 0
    for i < 4 {
        let body: Res = new Res("break-body-{i}")
        i += 1
        if i == 2 { continue }
        if i == 3 { break }
        seen += 1
    }
    return seen
}

fn main() {
    io.println("if {from_if(true)}")
    io.println("loop {from_loop()}")
    match from_try() {
        ok(v) => { io.println("try ok {v}") }
        err(e) => { io.println("try err") }
    }
    io.println("match {from_match(some(7))}")
    io.println("break {from_break()}")
}
