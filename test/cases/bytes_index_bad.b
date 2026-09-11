// Indexing a Bytes, which neither backend can emit.
//
// The checker used to accept this and type it `int`. The program then reached
// the interpreter as a panic saying indexing bytes "is not in the Beans
// interpreter yet" and the native build as an error about the LLVM emitter —
// two messages about the compiler for a program nothing had refused. Bytes has
// had `get` and `set` since it shipped, so there was never anything to emit.
package main

import std.io

fn main() {
    var buffer: Bytes = Bytes.from("abc")
    io.println("{buffer[0]}")
    buffer[1] = 90
}
