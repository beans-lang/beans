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
//   six    a six-element literal: more than the four a       0 backings
//          fresh list starts with, so the literal has to
//          ask for six or double its way there
//   twenty a twenty-element literal: 160 bytes of slots      1 backing
//          is past the threshold, but asking once still
//          costs one buffer where doubling costs four
//   slab   three 160-byte structs: one element alone is       1 backing
//          wider than the whole allowance, which is the
//          other way the fit test can answer no
//
// `wide` and `slab` are the half that proves the threshold is a threshold.
// Without them a runtime that put every buffer inline, at any size, would pass
// every other mode here and blow the pool's size classes in production.

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

fn six_round(index: int) -> int {
    var values: List<int> = [index, index + 1, index + 2, index + 3,
                             index + 4, index + 5]
    var total: int = 0
    for slot: int in 0..values.len() {
        total = total + values[slot]
    }
    return total
}

fn twenty_round(index: int) -> int {
    var values: List<int> = [
        index, index + 1, index + 2, index + 3, index + 4,
        index + 5, index + 6, index + 7, index + 8, index + 9,
        index + 10, index + 11, index + 12, index + 13, index + 14,
        index + 15, index + 16, index + 17, index + 18, index + 19]
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

struct Slab {
    pub cells: [int; 20]
}

fn slab_round(index: int) -> int {
    var rows: List<Slab> = []
    for step: int in 0..3 {
        var cells: [int; 20] =
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        cells[0] = index + step
        rows.push(Slab { cells: cells })
    }
    var total: int = 0
    for slot: int in 0..rows.len() {
        total = total + rows[slot].cells[0]
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
        } else if mode == "six" {
            total = total + six_round(index)
        } else if mode == "twenty" {
            total = total + twenty_round(index)
        } else if mode == "slab" {
            total = total + slab_round(index)
        } else if mode == "wide" {
            total = total + wide_round(index)
        } else {
            // Not a fallback: a mistyped mode in the gate would otherwise
            // count some other shape and pass.
            io.eprintln("unknown mode '{mode}'")
            os.exit(2)
        }
    }
    io.println("{mode} rounds={rounds} total={total}")
}
