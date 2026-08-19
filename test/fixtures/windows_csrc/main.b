package main

import std.io

extern "C" fn beans_windows_csrc_add(a: int, b: int) -> int

fn main() {
    var answer: int = 0
    unsafe {
        answer = beans_windows_csrc_add(19, 23)
    }
    io.println("windows csrc {answer}")
}
