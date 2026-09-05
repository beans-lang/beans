package main

import std.io
import app.limits
import {MAX_FRAME, FLAGS, SLOTS} from app.limits

// A cross-package const sizes a fixed array (#59), reached both ways a
// consumer can spell it, in a signature and in a field — the positions whose
// types are laid out before this package's own bodies are checked.
struct Row { cells: [int; limits.SLOTS] }

fn last_cell(row: [int; SLOTS]) -> int { return row[SLOTS - 1] }
fn grid() -> [[int; limits.SLOTS]; limits.ROWS] {
    return [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]]
}

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
    let sized: [int; SLOTS] = [7, 8, 9, 10]
    let qualified: [int; limits.SLOTS] = [1, 2, 3, 40]
    let row: Row = Row { cells: [0, 0, 0, 50] }
    io.println("sized {last_cell(sized)} {qualified[3]} {row.cells[3]} {grid()[2][3]}")
    io.println("interpolated {size_of([u8; limits.SLOTS])} {size_of([u8; SLOTS])}")
}
