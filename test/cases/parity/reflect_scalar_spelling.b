// A type's identity is not its spelling, on the reflection side too. `f64`
// and `float`, `i64` and `int`, `byte` and `u8` are one type each, and a
// program writes whichever it likes.
//
// Two tables answered `Kind` for a builtin scalar — the runtime's
// beans_reflect_type_kind and the tree interpreter's own copy — and BOTH were
// missing the same three aliases, so `f64` reported `other` and every
// reflective decoder mishandled the commoner spelling. Two implementations of
// one table is exactly why this belongs in the parity gate: fixing one and
// not the other turns a wrong answer into a backend disagreement.
package main

import std.io
import std.reflect

class Spellings {
    priv a: f64
    priv b: float
    priv c: i64
    priv d: int
    priv e: byte
    priv f: u8
    priv g: f32
    priv h: string
    priv i: bool
    priv j: Option<int>
    fn init(a: f64, b: float, c: i64, d: int, e: byte, f: u8, g: f32,
            h: string, i: bool, j: Option<int>) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
        self.g = g
        self.h = h
        self.i = i
        self.j = j
        io.println("arc+spellings")
    }
    fn deinit() { io.println("arc-spellings") }
}

fn main() {
    let subject: Spellings =
        new Spellings(1.0, 2.0, 3, 4, 5, 6, 7.0, "x", true, some(8))
    match type_of(Spellings).initializer() {
        some(maker) => {
            for parameter: reflect.Parameter in maker.parameters() {
                io.println("{parameter.name()} {parameter.type().qualified_name()} {parameter.type().kind()}")
            }
        }
        none => { io.println("no initializer") }
    }
    // The aliases must land on the same Kind as their canonical spellings.
    io.println("f64 is float {type_of(f64).kind() == type_of(float).kind()}")
    io.println("i64 is int {type_of(i64).kind() == type_of(int).kind()}")
    io.println("byte is u8 {type_of(byte).kind() == type_of(u8).kind()}")
}
