package main

import std.io

fn main() {
    // a static reading an earlier one resolves to its value, not a zero
    io.println("derived {Derived.doubled}")

    // every entry was built exactly once, before main ran
    io.println("built {Built.count}")

    var total: int = 0
    var i: int = 0
    for i < 5 {
        total = total + Gap.s2.size
        i += 1
    }
    io.println("reads {total} built {Built.count}")
    io.println("table {Gap.s1.size} {Gap.s2.size} {Gap.s3.size}")
}
