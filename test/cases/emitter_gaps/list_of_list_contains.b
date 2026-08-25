// gap: LLVM emitter does not support List<List<int>>.contains yet
//
// This used to be worse than a gap. The emitter handed the runtime an
// identity kind for a nested List, so `[[1, 2]].contains([1, 2])` answered
// true under `beansc run` and false in a native build — a wrong answer, in
// silence, with no diagnostic. It refuses now, which is the honest result
// until element equality is threaded through.
package main

import std.io

fn main() {
    var rows: List<List<int>> = [[1, 2]]
    io.println("{rows.contains([1, 2])}")
}
