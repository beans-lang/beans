import std.io

fn main() {
    var m: Map<string, int> = {}
    m["a"] = 1
    m["b"] = 2
    var ks: List<string> = m.keys()
    ks.sort()
    io.println(ks.len())
    let first: Option<int> = m.get("a")
    io.println(first.expect("missing a"))
    io.println(first.is_some())
    io.println(first.is_none())
    let r: Result<int> = "42".to_int()
    io.println(r.expect("bad int"))
}
