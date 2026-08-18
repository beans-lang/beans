import std.io

fn fail() -> Result<int> {
    return err("bad")
}

fn main() {
    io.println("float {1.25}")
    match fail() {
        ok(value) => io.println("ok {value}"),
        err(error) => io.println("error {error.msg}"),
    }
    io.println("after")
}
