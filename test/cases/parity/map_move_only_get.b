// B3: a Map whose value is move-only reads back through get(key), which
// answers Option<V>. The index forms stay refused — they would have to copy
// the value — and the read does not consume the entry.
package main

import std.io

fn main() {
    var m: Map<string, List<int>> = {}
    m.insert("a", [1, 2, 3])
    m.insert("b", [9])

    match m.get("a") {
        some(v) => { io.println("a len {v.len()} first {v[0]}") }
        none => { io.println("a missing") }
    }
    match m.get("absent") {
        some(v) => { io.println("unexpected {v.len()}") }
        none => { io.println("absent missing") }
    }
    io.println("still {m.len()}")

    // the value outlives the entry it came from
    match m.get("b") {
        some(v) => {
            m.clear()
            io.println("after clear {v.len()}")
        }
        none => { io.println("b missing") }
    }

    // iteration still reads the same values
    var n: Map<string, List<int>> = {}
    n.insert("k", [4, 5])
    for key: string, value: List<int> in n {
        io.println("iter {key} {value.len()}")
    }
    match n.get("k") {
        some(v) => { io.println("get after iter {v.len()}") }
        none => {}
    }
}
