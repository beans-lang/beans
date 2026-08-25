// gap: LLVM emitter does not support binary '==' for List<int> yet
//
// The checker accepts it and the interpreter answers correctly. Only the
// native backend refuses, so a program comparing two lists runs under
// `beansc run` and will not build.
package main

import std.io

fn main() {
    var a: List<int> = [1, 2, 3]
    var b: List<int> = [1, 2, 3]
    io.println("{a == b}")
}
