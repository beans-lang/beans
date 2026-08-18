import std.io

fn main() {
    let a: string = "left"
    let joined: string = a + "right"
    let n: int = joined.len()
    let tail: string = joined.slice(1, n)
    io.println("{joined} {n} {tail}")
}
