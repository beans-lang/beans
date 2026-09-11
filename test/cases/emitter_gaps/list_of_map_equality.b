// gap: LLVM emitter does not support binary '==' for List<Map<string, int>> yet
//
// Two lists of maps. The interpreter answers — a map is equal to no map, so
// two one-entry lists are unequal and two empty lists are equal by length —
// and the native build refuses the comparison outright.
//
// This probe replaces the List<List<int>> one, whose gap is closed: a nested
// list now takes the runtime's custom equality kind with request_value_eq's
// own structural comparator behind it, which is what the interpreter has
// always done. A Map has no equality to give it (spec/SYNTAX.md; the checker
// refuses a bare `m == n` outright), so this shape stays.
package main

import std.io

fn main() {
    let a: List<Map<string, int>> = [{}]
    let b: List<Map<string, int>> = [{}]
    let empty_a: List<Map<string, int>> = []
    let empty_b: List<Map<string, int>> = []
    io.println("one entry each: {a == b}")
    io.println("both empty: {empty_a == empty_b}")
}
