// Sorting a list whose element is an inline record. The native backend
// refused it — `sort_by` and `sort_by_key` only ever handled elements that
// fit one eight-byte slot, plus a hand-written decimal path — while the
// interpreter sorted them fine. crema could not build for this reason.
//
// A sort is a permutation, so the markers here are the real assertion: every
// owned pointer inside a moved element must come out the far side with the
// same reference count. A memcpy-based merge that retained or released would
// show as an unbalanced tag, and a comparator handed the wrong address would
// show as the wrong order.
package main

import std.io

class Tag {
    priv name: string

    fn init(name: string) {
        self.name = name
        io.println("arc+{name}")
    }

    fn deinit() { io.println("arc-{self.name}") }

    pub fn name_of() -> string { return self.name }
}

struct Row {
    tag: Tag
    rank: int
}

struct Pair {
    depth: int
    index: int
}

fn main() {
    // stability: equal depths keep the order they went in with
    var flat: List<Pair> = []
    flat.push(Pair { depth: 1, index: 0 })
    flat.push(Pair { depth: 2, index: 1 })
    flat.push(Pair { depth: 1, index: 2 })
    flat.push(Pair { depth: 2, index: 3 })
    flat.push(Pair { depth: 1, index: 4 })
    flat.sort_by(fn(a: Pair, b: Pair) -> bool { return a.depth < b.depth })
    var order: List<int> = []
    for p: Pair in flat { order.push(p.index) }
    io.println("stable {order[0]} {order[1]} {order[2]} {order[3]} {order[4]}")

    // a comparator reading two fields, descending — the shape crema uses
    flat.sort_by(fn(a: Pair, b: Pair) -> bool {
        if a.depth != b.depth { return a.depth > b.depth }
        return a.index > b.index
    })
    io.println("desc {flat[0].depth} {flat[0].index} {flat[4].depth}")

    // enough elements to run several merge widths
    var big: List<Pair> = []
    var i: int = 0
    for i < 40 {
        big.push(Pair { depth: (i * 7) % 13, index: i })
        i += 1
    }
    big.sort_by_key(fn(p: Pair) -> int { return p.depth })
    var ascending: bool = true
    var j: int = 1
    for j < big.len() {
        if big[j].depth < big[j - 1].depth { ascending = false }
        j += 1
    }
    io.println("big {big.len()} {ascending} {big[0].depth} {big[39].depth}")

    // records carrying an owned reference, moved by both sorts
    var rows: List<Row> = []
    rows.push(Row { tag: new Tag("cherry"), rank: 3 })
    rows.push(Row { tag: new Tag("apple"), rank: 1 })
    rows.push(Row { tag: new Tag("banana"), rank: 2 })
    rows.sort_by(fn(a: Row, b: Row) -> bool { return a.rank < b.rank })
    io.println("owned {rows[0].tag.name_of()} {rows[2].tag.name_of()}")
    rows.sort_by_key(fn(r: Row) -> int { return 0 - r.rank })
    io.println("owned key {rows[0].tag.name_of()} {rows[2].tag.name_of()}")

    // nothing to move, and nothing to compare
    var empty: List<Pair> = []
    empty.sort_by(fn(a: Pair, b: Pair) -> bool { return a.depth < b.depth })
    var one: List<Pair> = [Pair { depth: 4, index: 0 }]
    one.sort_by(fn(a: Pair, b: Pair) -> bool { return a.depth < b.depth })
    io.println("edges {empty.len()} {one.len()} {one[0].depth}")
}
