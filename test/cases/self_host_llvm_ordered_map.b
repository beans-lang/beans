import std.io

fn main() {
    var ordered: OrderedMap<string, int> =
        {"b": 2, "a": 1}
    ordered["c"] = 3
    ordered.remove("a")
    ordered["a"] = 10

    var copied: OrderedMap<string, int> =
        ordered.clone()
    copied["b"] = 20
    copied.remove("c")

    var plain: Map<string, int> =
        {"one": 1}
    var plain_copy: Map<string, int> =
        plain.clone()
    plain_copy["two"] = 2

    io.println(ordered.keys())
    io.println(ordered.values())
    io.println(copied.keys())
    io.println(
        "{ordered.get("b").or(0)} {copied.get("b").or(0)} {plain.len()} {plain_copy.len()}")
}
