import std.io

enum Shape {
    empty
    circle(r: float)
    tagged(name: string, n: int)
}

enum Chain {
    end
    link(label: string, rest: Chain)
}

struct Point {
    x: int
    label: string
}

enum Holder<T> {
    of(v: T)
    nothing
}

enum Slot {
    at(p: Point)
    free
}

fn chain_text(c: Chain) -> string {
    match c {
        end => { return "." },
        link(label, rest) => {
            return "{label}>{chain_text(rest)}"
        },
    }
}

fn wild(s: Shape) -> string {
    match s {
        circle(r) => { return "c{r}" },
        _ => { return "other" },
    }
}

fn main() {
    // borrowed payload construction: nm stays usable after the box takes a copy
    let nm: string = "kept"
    let t: Shape = Shape.tagged(nm, 3)
    io.println("nm={nm}")
    match t {
        tagged(name, n) => { io.println("t={name}#{n}") },
        _ => { io.println("no") },
    }

    // nested enum payloads, recursion through the box
    let c: Chain =
        Chain.link("a", Chain.link("b", Chain.end))
    io.println(chain_text(c))

    // wildcard arm
    io.println(wild(Shape.circle(1.5)))
    io.println(wild(Shape.empty))

    // record payload: construction, extraction, nested string ARC
    let p: Point = Point { x: 4, label: "pt" }
    let s: Slot = Slot.at(p)
    match s {
        at(q) => { io.println("{q.label}:{q.x}") },
        free => { io.println("free") },
    }

    // generic enums
    let gi: Holder<int> = Holder.of(41)
    let gs: Holder<string> = Holder.of("gen")
    match gi {
        of(v) => { io.println("gi={v}") },
        nothing => { io.println("gi=none") },
    }
    match gs {
        of(v) => { io.println("gs={v}") },
        nothing => { io.println("gs=none") },
    }

    // lists of payload enums
    var shapes: List<Shape> = []
    shapes.push(Shape.circle(2.0))
    shapes.push(Shape.tagged("z", 9))
    io.println(shapes.len())
    io.println(wild(shapes[0]))

    // structural equality: nested payloads, mixed variants
    io.println(Shape.tagged("x", 1) == Shape.tagged("x", 1))
    io.println(Shape.tagged("x", 1) == Shape.tagged("y", 1))
    io.println(Shape.tagged("x", 1) == Shape.empty)
    io.println(Shape.empty == Shape.empty)
    io.println(c == Chain.link("a", Chain.link("b", Chain.end)))
    io.println(c != Chain.link("a", Chain.end))
    io.println(gi == Holder.of(41))
    io.println(gs != Holder.of("other"))
}
