// A cached loop nested inside an iteration of the same list. The cache is
// allowed here — the iterator is not advanced while it is open — but only
// because the write-back on the way out is exact: the outer loop compares
// the change word on its next turn, and a count still sitting in a register
// would let it walk a list that moved under it.
import std.io
fn main() {
    var xs: List<int> = [1, 2, 3, 4, 5]
    for x: int in xs {
        var k: int = 0
        for k < 2 { xs.push(x) ; k += 1 }
    }
    io.println("this loop had to refuse, len={xs.len()}")
}
