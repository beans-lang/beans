// sort_by and sort_by_key over an element wider than one runtime slot.
//
// The comparator arrives with the call, so nothing about the element type is
// needed to run one — and yet `List<Option<int>>` and `List<Result<int,
// string>>` were refused while `List<Point>` and `List<Option<string>>` sorted.
// The line was drawn at the element's spelling (decimal, or a struct
// declaration) rather than at its width, and every wide inline value is stored
// by the list's own stride, so all of them can take the same by-address thunk a
// struct takes.
//
// Sorts run twice over the same data with keys that tie, so a backend whose
// stable sort is not stable shows up as a different order rather than as a
// different multiset.
package main

import std.io

struct Point { x: int, y: int }

fn main() {
    var slots: List<Option<int>> = [some(3), none, some(1), some(2), none]
    slots.sort_by(fn (l: Option<int>, r: Option<int>) -> bool {
        return l.or(-1) < r.or(-1)
    })
    io.println("option-int {slots}")

    var places: List<Option<Point>> = [
        some(Point { x: 3, y: 0 }),
        none,
        some(Point { x: 1, y: 9 }),
        some(Point { x: 1, y: 0 }),
    ]
    places.sort_by_key(fn (v: Option<Point>) -> int {
        return match v { some(p) => p.x, none => -1 }
    })
    io.println("option-point {places}")

    var answers: List<Result<int, string>> = [ok(3), err("z"), ok(1), ok(1)]
    answers.sort_by_key(fn (v: Result<int, string>) -> int {
        return v.or(-1)
    })
    io.println("result {answers}")

    var words: List<Option<string>> = [some("b"), none, some("a"), some("b")]
    words.sort_by(fn (l: Option<string>, r: Option<string>) -> bool {
        return l.or("") < r.or("")
    })
    io.println("option-string {words}")

    var records: List<Point> = [
        Point { x: 2, y: 1 },
        Point { x: 1, y: 2 },
        Point { x: 2, y: 0 },
    ]
    records.sort_by_key(fn (p: Point) -> int { return p.x })
    io.println("struct {records}")

    var amounts: List<decimal> = [2.5 as decimal, 1.25 as decimal, 2.5 as decimal]
    amounts.sort_by(fn (l: decimal, r: decimal) -> bool { return l < r })
    io.println("decimal {amounts}")

    var pairs: List<Option<Option<int>>> = [some(some(2)), some(none), none, some(some(1))]
    pairs.sort_by_key(fn (v: Option<Option<int>>) -> int {
        return match v {
            some(inner) => inner.or(50),
            none => 100,
        }
    })
    io.println("nested-option {pairs}")
}
