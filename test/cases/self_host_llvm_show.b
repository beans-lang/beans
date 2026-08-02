// every showable shape the emitter renders through the memoized
// show functions: lists of each scalar kind, nested and empty
// lists, options in interpolation (both the pointer form and the
// wide {i1, T} form), and Result.or across Error, string, and
// defaulted error types. Output must match the interpreter's
// display() byte for byte.
import std.io

fn risky(flag: bool) -> Result<int, string> {
    if flag { return ok(7) }
    return err("boom")
}

fn checked(n: int) -> Result<int> {
    if n < 1 {
        return err("bad {n}")
    }
    return ok(n)
}

// A wide payload stays inline in Result beside its error arm.
// This also pins the nested Option layout.
fn probe(flag: bool) -> Result<Option<int>, string> {
    if flag {
        return ok(some(41))
    }
    return ok(none)
}

struct Point {
    x: int
    y: int
}

fn locate(flag: bool) -> Result<Point, string> {
    if flag {
        return ok(Point { x: 3, y: 4 })
    }
    return err("lost")
}

fn main() {
    let xs: List<int> = [1, 2, 3]
    io.println(xs)
    io.println("{xs}")
    let names: List<string> = ["a", "b"]
    io.println(names)
    io.println("{names}")
    let nested: List<List<int>> = [[1], [2, 3]]
    io.println(nested)
    let fs: List<float> = [1.5, 2.0]
    io.println(fs)
    let halves: List<f32> = [0.25 as f32, 4.5 as f32]
    io.println(halves)
    let bs: List<bool> = [true, false]
    io.println(bs)
    let ds: List<decimal> = [1.10, 2.25]
    io.println(ds)
    let us: List<u8> = [200 as u8, 5 as u8]
    io.println(us)
    let empty: List<int> = []
    io.println(empty)
    io.println("{empty} {nested}")

    let maybe: Option<int> = some(7)
    let nothing: Option<int> = none
    io.println("{maybe} {nothing}")
    let held: Option<string> = some("beans")
    let missing: Option<string> = none
    io.println("{held} {missing}")
    let wrapped: Option<List<int>> = some([5, 6])
    io.println("{wrapped}")

    io.println(risky(true).or(0))
    io.println(risky(false).or(-1))
    io.println(checked(3).or(-1))
    io.println(checked(0).or(-1))

    match probe(true) {
        ok(found) => { io.println("{found}") }
        err(problem) => { io.println(problem) }
    }
    match probe(false) {
        ok(found) => { io.println("{found}") }
        err(problem) => { io.println(problem) }
    }
    match locate(true) {
        ok(point) => { io.println("{point.x} {point.y}") }
        err(problem) => { io.println(problem) }
    }
    match locate(false) {
        ok(point) => { io.println("{point.x} {point.y}") }
        err(problem) => { io.println(problem) }
    }
}
