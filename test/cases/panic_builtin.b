import std.io

fn reason() -> string {
    return "stopped"
}

fn main() {
    io.println("before panic")
    panic(reason())
    io.println("after panic")
}
