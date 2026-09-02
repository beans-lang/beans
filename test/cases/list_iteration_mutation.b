// A structural change to the list a loop is reading stops the loop.
// spec/SYNTAX.md, "Changing a collection while a loop reads it". Driven by
// test/list_iteration.sh, which asserts both backends refuse it identically;
// the whole mutation-by-size matrix is tools/list_iteration_probe.py.
import std.io

fn main() {
    var values: List<int> = [1, 2, 3, 4, 5]
    var seen: int = 0
    for value: int in values {
        seen += 1
        io.println("saw {value}")
        if seen == 2 { values.push(value + 100) }
    }
    io.println("finished {seen}")
}
