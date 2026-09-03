package main

import std.io
import app.limits
import {MAX_FRAME, FLAGS} from app.limits

// A cross-package const reaches a match arm through an import binding, the
// spelling a consumer uses.
fn describe(n: int) -> string {
    return match n {
        MAX_FRAME => "max",
        FLAGS => "flags",
        _ => "other",
    }
}

fn main() {
    io.println("qualified {limits.MAX_FRAME} {limits.NAME} {limits.FLAGS}")
    io.println("imported {MAX_FRAME} {FLAGS}")
    io.println("match {describe(1048576)} {describe(9)} {describe(2)}")
    let frame: [int; 4] = [limits.FLAGS, MAX_FRAME, limits.MAX_FRAME + 1, 0]
    io.println("used {frame[0]} {frame[1]} {frame[2]}")
}
