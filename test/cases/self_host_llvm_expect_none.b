import std.io

fn main() {
    var m: Map<string, int> = {}
    io.println("before")
    let missing: Option<int> = m.get("nope")
    io.println(missing.expect("empty map has no nope"))
}
