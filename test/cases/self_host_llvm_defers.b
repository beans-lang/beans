// Defers through the self-host LLVM emitter: registration flags, LIFO
// order at every exit, exit-time capture reads through shared cells,
// `?` exits above and below the defer statement, and the real
// std.fs close-on-exit pattern.
import std.io
import std.fs

fn plain() {
    defer io.println("plain: closed")
    io.println("plain: body")
}

fn stacked(early: bool) -> int {
    defer io.println("stacked: first registered")
    defer io.println("stacked: second registered")
    if early {
        io.println("stacked: early exit")
        return 1
    }
    io.println("stacked: late exit")
    return 2
}

fn exit_time_value() {
    var count: int = 1
    defer io.println("exit sees count {count}")
    count = 41
    count += 1
    io.println("body set count to {count}")
}

fn captured_string() -> string {
    let name: string = "beans"
    defer io.println("goodbye {name}")
    return "hello {name}"
}

fn parse_even(text: string) -> Result<int> {
    let value: int = text.to_int()?
    defer io.println("checked {value}")
    if value % 2 != 0 {
        return err("odd number {value}")
    }
    return ok(value)
}

fn file_roundtrip() -> Result<string> {
    let path: string = "build/self_host_defers.txt"
    fs.write(path, "defer closed this file\n")?
    let text: string = fs.read(path)?
    return ok(text)
}

fn describe(result: Result<int>) -> string {
    match result {
        ok(value) => { return "ok {value}" }
        err(problem) => { return "err {problem.msg}" }
    }
}

// A defer registered inside a nested block still sees that block's
// bindings when it runs at function exit. Native reads the stack slot;
// the tree walker once dropped the block's scope and panicked with
// "unknown name" — the deferred record now carries its frame.
fn nested_scope(deep: bool) {
    if deep {
        let keep: int = 12
        defer io.println("nested defer sees {keep}")
        io.println("nested body ran")
    }
    io.println("after the nested block")
}

fn main() {
    defer io.println("main: last words")
    plain()
    io.println("stacked -> {stacked(true)}")
    io.println("stacked -> {stacked(false)}")
    exit_time_value()
    io.println(captured_string())
    io.println(describe(parse_even("12")))
    io.println(describe(parse_even("7")))
    io.println(describe(parse_even("beans")))
    nested_scope(true)
    match file_roundtrip() {
        ok(text) => { io.println("read back: {text}") }
        err(problem) => { io.println("file failed: {problem.msg}") }
    }
    io.println("main: done")
}
