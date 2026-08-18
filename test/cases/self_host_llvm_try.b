import std.io

fn parse_two(a: string, b: string) -> Result<int> {
    let x: int = a.to_int()?
    let y: int = b.to_int()?
    return ok(x + y)
}

fn main() {
    match parse_two("2", "40") {
        ok(v) => { io.println("sum {v}") },
        err(e) => { io.println("bad: {e.msg}") },
    }
    match parse_two("2", "nope") {
        ok(v) => { io.println("sum {v}") },
        err(e) => { io.println("bad: {e.msg} kind={e.kind}") },
    }
    match parse_two("x", "1") {
        ok(v) => { io.println("sum {v}") },
        _ => { io.println("fell through") },
    }
}
