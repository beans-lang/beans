import std.io

fn narrow(flag: bool) -> Result<int, string> {
    if flag { return ok(7) }
    return err("bad")
}

fn defaulted(flag: bool) -> Result<int> {
    if flag { return ok(7) }
    return err("bad")
}

fn main() {
    match narrow(true) {
        ok(value) => { io.println("narrow {value}") }
        err(problem) => { io.println("bad {problem}") }
    }
    match narrow(false) {
        ok(value) => { io.println("bad {value}") }
        err(problem) => { io.println("narrow {problem}") }
    }
    io.println("default {defaulted(false).is_ok()}")
}
