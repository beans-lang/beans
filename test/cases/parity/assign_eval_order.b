// target[k] = v evaluates left to right on both backends: receiver, then
// key, then value — the order the source reads and MIR lowers. The
// interpreter once evaluated the value first, so a side-effecting key and
// value observably swapped between the legs (native printed "key, val"
// while the interpreter printed "val, key"). Reverting the interpreter's
// index-first hoist swaps these lines again.
import std.io

fn traced_key(tag: string) -> string {
    io.println("  key {tag}")
    return tag
}

fn traced_idx(tag: string, n: int) -> int {
    io.println("  idx {tag}")
    return n
}

fn traced_val(tag: string, n: int) -> int {
    io.println("  val {tag}")
    return n
}

fn main() {
    var m: Map<string, int> = {}
    m[traced_key("m")] = traced_val("m-insert", 1)
    m[traced_key("m")] = traced_val("m-replace", 2)
    io.println("map {m.len()} {m.get("m").or(0)}")
    var l: List<int> = [1, 2, 3]
    l[traced_idx("list", 1)] = traced_val("list", 9)
    io.println("list {l[0]} {l[1]} {l[2]}")
    var a: [int; 2] = [5, 6]
    a[traced_idx("array", 0)] = traced_val("array", 7)
    io.println("array {a[0]} {a[1]}")
    // compound element assignment: the index runs once, before the
    // right-hand side (the interpreter once ran the value first and the
    // index twice — once reading, once storing)
    a[traced_idx("compound", 1)] += traced_val("compound", 10)
    io.println("compound {a[0]} {a[1]}")
}
