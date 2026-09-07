// What a list costs in blocks, counted rather than assumed.
//
// A list is a 48-byte header and an element buffer. A buffer small enough to
// fit rides inside the header's own block; anything else gets a block of its
// own, and so does every buffer a list grows into. `list_backings` in the
// -DBEANS_ARC_STATS report counts exactly the blocks of the second kind, which
// `allocations` cannot see — a backing is not an object and never went through
// beans_alloc.
//
// The gate runs each mode at two round counts and reads the difference, so the
// answer does not depend on what the process allocates on the way to main.
//
//   small  three ints, never grows                     0 backings per round
//   grow   nine ints: 4 -> 8 -> 16, two grows          2 backings per round
//   wide   three 40-byte structs: 4 x 40 = 160 bytes,  1 backing  per round
//          too much to carry behind a header
//
// `wide` is the half that proves the threshold is a threshold. Without it a
// runtime that put every buffer inline, at any size, would pass.

import std.io
import std.os

struct Five {
    pub a: int
    pub b: int
    pub c: int
    pub d: int
    pub e: int
}

fn small_round(index: int) -> int {
    var values: List<int> = [index, index + 1, index + 2]
    var total: int = 0
    for slot: int in 0..values.len() {
        total = total + values[slot]
    }
    return total
}

fn grow_round(index: int) -> int {
    var values: List<int> = []
    for step: int in 0..9 {
        values.push(index + step)
    }
    var total: int = 0
    for slot: int in 0..values.len() {
        total = total + values[slot]
    }
    return total
}

fn wide_round(index: int) -> int {
    var rows: List<Five> = []
    for step: int in 0..3 {
        rows.push(Five { a: index, b: step, c: 0, d: 0, e: index + step })
    }
    var total: int = 0
    for slot: int in 0..rows.len() {
        total = total + rows[slot].a + rows[slot].e
    }
    return total
}

fn main() {
    let mode: string = os.env("MODE").or("small")
    let rounds: int = os.env("ROUNDS").or("1000").to_int().or(1000)
    var total: int = 0
    for index: int in 0..rounds {
        if mode == "small" {
            total = total + small_round(index)
        } else if mode == "grow" {
            total = total + grow_round(index)
        } else {
            total = total + wide_round(index)
        }
    }
    io.println("{mode} rounds={rounds} total={total}")
}
