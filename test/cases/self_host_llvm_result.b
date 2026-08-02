import std.io

fn half(n: int) -> Result<int> {
    if n % 2 != 0 {
        return err("odd {n}")
    }
    return ok(n / 2)
}

fn main() {
    match half(10) {
        ok(v) => { io.println("ok {v}") },
        err(e) => { io.println("err {e.msg}") },
    }
    match half(3) {
        ok(v) => { io.println("ok {v}") },
        err(e) => { io.println("err {e.msg}") },
    }
}
