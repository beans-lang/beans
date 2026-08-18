// a wide Option owns whatever its payload owns: Map.get retains a
// copy into {i1, T} and List.pop moves one in, so an Option that
// dies unconsumed must release the payload's references. Drops
// once skipped the whole aggregate — pointer masks answer 0 for
// Option, no declaration backs it — and these deinits never ran.
import std.io

class Tracer {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("drop {self.name}")
    }
}

struct Row {
    tag: Tracer
    score: int
}

fn hold_one(table: Map<string, Row>) {
    let held: Option<Row> = table.get("k")
    io.println("held")
}

fn steal(rows: List<Row>) {
    let popped: Option<Row> = rows.pop()
    io.println("popped")
}

fn consume(table: Map<string, Row>) {
    match table.get("k") {
        some(row) => { io.println("hit {row.score}") }
        none => { io.println("miss") }
    }
}

fn main() {
    var table: Map<string, Row> = {}
    table["k"] = Row { tag: new Tracer("owned"), score: 9 }
    hold_one(table)
    io.println("took")
    consume(table)

    var rows: List<Row> = []
    rows.push(Row { tag: new Tracer("moved"), score: 1 })
    steal(rows)
    io.println("stole")

    let missing: Option<Row> = table.get("absent")
    match missing {
        some(row) => { io.println("ghost {row.score}") }
        none => { io.println("none stayed none") }
    }
    io.println("end")
}
