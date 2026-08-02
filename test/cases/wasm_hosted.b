import std.io
import std.os
import std.c

fn main() {
    let args: List<string> = os.args()
    io.println("args {args.len()} {args.get(0).or("missing")}")
    io.println("env {os.env("BEANS_WASM_TEST").or("missing")}")
    io.println("unset {os.env("BEANS_WASM_UNSET").is_none()}")

    c.set_errno(7)
    io.println("errno {c.errno()}")

    io.println("line {io.read_line().or("eof")}")
    io.println("rest {io.read_all()}")
}
