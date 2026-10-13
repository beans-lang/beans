// `bytes[i]`, `bytes[i] = v` and `bytes.set(i, v)` compile to an inline
// length check and byte access. In range they read and write exactly one
// byte, and a write keeps the value's low eight bits. Out of range, at either
// end, each still panics with the runtime's message, and a `contained` call
// still catches that panic.
package main

import std.io

fn read(data: Bytes, at: int) -> int {
    return data[at]
}

fn write(data: Bytes, at: int, value: int) -> bool {
    data[at] = value
    return true
}

fn store(data: Bytes, at: int, value: int) -> bool {
    data.set(at, value)
    return true
}

fn main() {
    var data: Bytes = Bytes.filled(4, 9)
    data[0] = 300
    data.set(1, -1)
    data[3] = 255
    io.println("bytes {data[0]} {data[1]} {data[2]} {data[3]}")

    for at: int in [-1, 4, 1000] {
        match contained read(data, at) {
            ok(value) => io.println("read {at} gave {value}"),
            err(e) => io.println("read {at}: {e.msg}"),
        }
        match contained write(data, at, 1) {
            ok(done) => io.println("write {at} gave {done}"),
            err(e) => io.println("write {at}: {e.msg}"),
        }
        match contained store(data, at, 1) {
            ok(done) => io.println("set {at} gave {done}"),
            err(e) => io.println("set {at}: {e.msg}"),
        }
    }
    io.println("still {data[0]} {data[1]} {data[2]} {data[3]} len {data.len()}")
}
