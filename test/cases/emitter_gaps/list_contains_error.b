// gap: LLVM emitter does not support List<Error>.contains yet
//
// `Error` satisfies Eq (spec/SYNTAX.md, "Interfaces"), so `contains` is
// offered on a List<Error>; the emitter has no comparator for it and refuses.
// This probe replaces the List<List<int>> one, whose gap is closed.
//
// Recorded here because the probe would otherwise look like it proves more
// than it does: the answer the interpreter prints is WRONG. It compares two
// Error values with tree_value_total_equal, which has no arm for an error, so
// every pair is unequal — including a value against itself, which is why
// `contains` answers false for an element that is literally in the list. A
// bare `e == e` answers false for the same reason and the native build refuses
// that too, so `Error ==` is its own backend split and not this gap. Fixing it
// means deciding what equality on an Error is — identity, like every other
// class, or its fields — and giving BOTH backends that answer; neither has it
// today. The claim this probe makes, and the only one, is that the program
// runs under the interpreter and will not build.
package main

import std.io

fn main() {
    let boom: Error = new Error("boom")
    let errors: List<Error> = [boom]
    io.println("holds it: {errors.contains(boom)}")
    io.println("count: {errors.len()}")
}
