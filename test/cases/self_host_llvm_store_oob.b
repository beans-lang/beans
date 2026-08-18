import std.io

fn main() {
    var xs: List<string> = []
    xs.push("only")
    io.println("before")
    xs[3] = "nope"
    io.println("after")
}
