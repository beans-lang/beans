// Derived rendering of the shapes the language builds out of other values.
// A map prints as {k: v} in insertion order — the order keys() walks — and
// every backend must print these bytes for byte. This case grows one issue
// at a time (#34); maps land first.
import std.io

fn main() {
    // A map, its keys and values rendered, wrapped in braces.
    let basic: Map<string, int> = {"a": 1, "b": 2}
    io.println("{basic}")

    // An empty map is a pair of braces, nothing between.
    let empty: Map<string, int> = {}
    io.println("{empty}")

    // Nesting: a list value, an option value, a map value.
    let lists: Map<string, List<int>> = {"xs": [1, 2], "ys": []}
    io.println("{lists}")
    let opts: Map<int, Option<string>> = {1: some("hi"), 2: none}
    io.println("{opts}")
    let maps: Map<string, Map<string, int>> = {"outer": {"inner": 5}}
    io.println("{maps}")

    // Insertion order holds across an in-place update and a
    // delete-then-reinsert: an updated key keeps its place, a reinserted
    // one goes to the end.
    var edited: Map<string, int> = {}
    edited["z"] = 1
    edited["a"] = 2
    edited["z"] = 9
    io.println("{edited}")
    edited.remove("z")
    edited["z"] = 100
    io.println("{edited}")

    // A map is one printable value: width pads its rendered form in columns.
    io.println("|{basic:20}|")
}
