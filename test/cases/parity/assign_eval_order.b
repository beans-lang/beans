// target[k] = v and target.f = v evaluate left to right on both backends:
// receiver, then key, then value — the order the source reads and MIR
// lowers. The interpreter once evaluated the value first, so a
// side-effecting key and value observably swapped between the legs (native
// printed "key, val" while the interpreter printed "val, key"). Reverting
// the interpreter's index-first or field-first hoist swaps these lines
// again.
//
// A field target had a second half of the same fault, and it is the one a
// diff of answers cannot see: the compound read re-evaluated the whole
// target, so `holder().n += 1` called holder() twice on the interpreter and
// once natively. The receiver here prints, so running it twice shows up as
// an extra line rather than as a wrong number.
import std.io

class Counter {
    pub n: int = 0
    pub p: Pair = Pair { a: 0, b: 0 }
}

struct Pair {
    a: int
    b: int
}

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

fn traced_obj(tag: string, counter: Counter) -> Counter {
    io.println("  obj {tag}")
    return counter
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
    // a field target: the receiver runs before the right-hand side, and
    // exactly once whatever the operator is
    let counter: Counter = new Counter()
    traced_obj("field", counter).n = traced_val("field", 3)
    io.println("field {counter.n}")
    traced_obj("field-compound", counter).n += traced_val("field-compound", 4)
    io.println("field-compound {counter.n}")
    // the same for a record place inside that heap object
    traced_obj("record", counter).p.a = traced_val("record", 5)
    io.println("record {counter.p.a}")
    traced_obj("record-compound", counter).p.a += traced_val("record-compound", 6)
    io.println("record-compound {counter.p.a}")
}
