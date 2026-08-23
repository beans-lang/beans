import std.io

fn main() {
    let n: int = 7
    // \{ never opens a slot, before, between, or after real slots
    io.println("A: \{\} n={n}")
    io.println("B: \{n\} and {n + 1}")
    io.println("C: {n:4} \{pad\}")
    io.println("D: \{{n}\}")
    // escapes inside a slot's own string stay escapes
    io.println("E: {"x\{y"} z")
    // doubled braces are not escapes: each one renders
    io.println("F: \{\{ \}\} done")
    // the classic escapes still mean what they meant
    io.println("G: tab\there \"quoted\" back\\slash")
    // a bare closing brace outside a slot is plain text
    io.println("H: closer } alone")
}
