// Wide records inside collection queries through the self-host LLVM
// emitter: Map.get building an owned Option around a retained copy,
// List.pop moving the last element out, and join over non-string
// element kinds.
import std.io

struct Row {
    label: string
    score: int
}

fn main() {
    var table: Map<string, Row> = {}
    table["a"] = Row { label: "alpha", score: 1 }
    table["b"] = Row { label: "beta", score: 2 }
    match table.get("a") {
        some(row) => { io.println("hit {row.label} {row.score}") }
        none => { io.println("miss") }
    }
    match table.get("zz") {
        some(row) => { io.println("hit {row.label}") }
        none => { io.println("miss") }
    }
    var numbered: Map<int, Row> = {}
    numbered[7] = Row { label: "seven", score: 70 }
    match numbered.get(7) {
        some(row) => { io.println("hit {row.label} {row.score}") }
        none => { io.println("miss") }
    }
    match numbered.get(8) {
        some(row) => { io.println("hit {row.label}") }
        none => { io.println("miss") }
    }

    var rows: List<Row> = []
    rows.push(Row { label: "one", score: 1 })
    rows.push(Row { label: "two", score: 2 })
    match rows.pop() {
        some(last) => { io.println("popped {last.label} {last.score}") }
        none => { io.println("empty") }
    }
    match rows.pop() {
        some(last) => { io.println("popped {last.label} {last.score}") }
        none => { io.println("empty") }
    }
    match rows.pop() {
        some(last) => { io.println("popped {last.label}") }
        none => { io.println("empty") }
    }

    let widths: List<int> = [8, 16, 32, 64]
    io.println("atomics {widths.join(",")}")
    let flags: List<bool> = [true, false]
    io.println("flags {flags.join("|")}")
    let ratios: List<float> = [1.5, 2.25]
    io.println("ratios {ratios.join(" and ")}")
}
