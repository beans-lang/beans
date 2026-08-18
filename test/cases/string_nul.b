package main

import std.io

fn main() {
    let value: string = "a\0b"
    io.println("{value.len()} {value.byte_at(1)}")
}
