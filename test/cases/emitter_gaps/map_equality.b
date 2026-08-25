// gap: LLVM emitter does not support binary '==' for Map<string, int> yet
package main

import std.io

fn main() {
    var a: Map<string, int> = {}
    a.insert("k", 1)
    var b: Map<string, int> = {}
    b.insert("k", 1)
    io.println("{a == b}")
}
