// gap: LLVM emitter does not support builtin method 'List<int>.is_empty' yet
//
// `a.len() == 0` compiles natively and `a.is_empty()` does not, which is the
// clearest sign this is an unwritten case rather than a design limit.
package main

import std.io

fn main() {
    var a: List<int> = []
    io.println("{a.is_empty()}")
}
