// `panic(...)` does not come back, so a body that ends in one has returned as
// far as anyone can observe. Both halves had to move together: the checker's
// end-of-body walk and MIR's own fallthrough check. Fixing only the checker
// would have made the interpreter accept a program the native backend
// refuses, which is the bug class this file exists to catch.
//
// The negative cases live in test/language_gaps.sh: a panic in one arm of an
// `if` without an else, or in a loop body that may run zero times, still has
// to be refused.
package main

import std.io

fn pick(n: int) -> int {
    if n > 0 {
        return n
    }
    panic("not positive")
}

fn label(n: int) -> string {
    match n {
        0 => { return "zero" }
        _ => { panic("only zero") }
    }
}

fn nested(n: int) -> int {
    if n > 0 {
        if n > 100 {
            panic("too big")
        }
        return n
    }
    panic("not positive")
}

fn either(n: int) -> int {
    if n > 0 {
        return n
    } else {
        panic("not positive")
    }
}

class Table {
    static fn at(index: int) -> string {
        if index == 0 {
            return "first"
        }
        panic("out of range")
    }
}

fn main() {
    io.println("pick {pick(3)}")
    io.println("label {label(0)}")
    io.println("nested {nested(7)}")
    io.println("either {either(9)}")
    io.println("static {Table.at(0)}")

    // a closure body ends in a panic too
    let close: fn(int) -> int = fn(n: int) -> int {
        if n > 0 {
            return n
        }
        panic("closure")
    }
    io.println("closure {close(5)}")
}
