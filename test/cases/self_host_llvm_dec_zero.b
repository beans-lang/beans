import std.io

fn main() {
    var top: decimal = 5.0
    var bottom: decimal = 0.0
    io.println("before")
    let broken: decimal = top / bottom
    io.println("unreachable {broken}")
}
