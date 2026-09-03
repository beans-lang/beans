// A push and a pop inside one turn leave the length exactly where it was, so
// the only thing that can tell the outer iteration its list moved is the
// change count. A cache that carried the count but wrote back a stale one —
// or never counted at all — would let this loop run to completion.
import std.io
fn main() {
    var xs: List<int> = [1, 2, 3, 4, 5]
    for x: int in xs {
        var k: int = 0
        for k < 1 {
            xs.push(x)
            match xs.pop() {
                some(v) => {}
                none => {}
            }
            k += 1
        }
    }
    io.println("this loop had to refuse, len={xs.len()}")
}
