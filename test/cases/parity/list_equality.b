// `List<T> == List<T>` and `List<T>.is_empty()`, reported from the first real
// workload: comparing a parsed keystroke sequence and a parsed context stack,
// twice in one package. The interpreter had always answered these; only the
// native backend refused, so any package that parses input into a list and
// compares it could run but not build.
//
// Elements compare the way the interpreter compares them — by content for a
// string, structurally for a record, by identity for a class. That last
// distinction is the point of the class rows below: two separately built
// instances holding equal fields are NOT equal, and a gate that only checked
// `true == true` would not notice a backend getting it backwards.
package main

import std.io

struct Entry {
    key: string
    value: Option<string>
}

class Node {
    pub v: int

    fn init(v: int) { self.v = v }
}

fn main() {
    var a: List<int> = [1, 2, 3]
    var b: List<int> = [1, 2, 3]
    var shorter: List<int> = [1, 2]
    var different: List<int> = [1, 2, 4]
    io.println("int {a == b} {a == shorter} {a == different} {a != different}")

    var s1: List<string> = ["x", "y"]
    var s2: List<string> = ["x", "y"]
    var s3: List<string> = ["x", "z"]
    io.println("string {s1 == s2} {s1 == s3}")

    var f1: List<float> = [1.5, 2.5]
    var f2: List<float> = [1.5, 2.5]
    var f3: List<float> = [1.5, 9.5]
    io.println("float {f1 == f2} {f1 == f3}")

    // a record holding a string and an Option — the crema shape
    var e1: List<Entry> = [Entry { key: "a", value: some("1") }]
    var e2: List<Entry> = [Entry { key: "a", value: some("1") }]
    var e3: List<Entry> = [Entry { key: "a", value: none }]
    var e4: List<Entry> = [Entry { key: "b", value: some("1") }]
    io.println("record {e1 == e2} {e1 == e3} {e1 == e4}")

    // classes compare by identity, not by field
    let shared: Node = new Node(1)
    var c1: List<Node> = [shared]
    var c2: List<Node> = [shared]
    var c3: List<Node> = [new Node(1)]
    io.println("class {c1 == c2} {c1 == c3}")

    // empty lists, and a length mismatch against a non-empty one
    var z1: List<Entry> = []
    var z2: List<Entry> = []
    io.println("empty {z1 == z2} {z1 == e1} {z1.is_empty()} {e1.is_empty()}")

    io.println("is_empty {a.is_empty()} {a.len()}")

    // In branch position, not just interpolated. Wiring `is_empty` through
    // the length path once caught `string.is_empty()` on the way past and
    // handed `br` an i64 where it wanted an i1 — invisible to a test that
    // only ever printed the value.
    let blank: string = ""
    let filled: string = "abc"
    if blank.is_empty() { io.println("blank empty") } else { io.println("blank full") }
    if filled.is_empty() { io.println("filled empty") } else { io.println("filled full") }
    if z1.is_empty() { io.println("list empty") } else { io.println("list full") }
    if a.is_empty() { io.println("ints empty") } else { io.println("ints full") }
    if a == b { io.println("branch equal") } else { io.println("branch unequal") }
    if a == different { io.println("branch equal2") } else { io.println("branch unequal2") }
    io.println("string is_empty {blank.is_empty()} {filled.is_empty()} {filled.len()}")
}
