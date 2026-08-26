// gap: LLVM emitter does not support binary '==' for List<List<int>> yet
//
// `List<T> ==` builds now for the element types whose meaning the backend can
// match. A nested List is not one of them: the interpreter compares the inner
// lists structurally, and the only kind the runtime scan offers for them is
// identity, which would answer a different question. Refused until element
// equality is threaded through — the same piece of work `List<Struct>`
// contains and index_of are waiting on.
package main

import std.io

fn main() {
    var rows: List<List<int>> = [[1, 2], [3]]
    var same: List<List<int>> = [[1, 2], [3]]
    io.println("{rows == same}")
}
