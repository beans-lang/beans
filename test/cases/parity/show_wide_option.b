// Printing an Option whose payload is wider than one runtime slot.
//
// `io.println("{v}")` on an `Option<Point>` prints `some(Point { x: 1, y: 2 })`
// under `beansc run`. The native build refused it: show_value handed the
// payload to the show driver as a slot, and a struct, a decimal, a nested
// Option or an inline Result has no slot form — request_show answered "" and
// the whole build failed on a debug print of an optional struct.
//
// A wide payload crosses by address instead, the way every other wide value is
// shown: the Option is spilled whole and request_show_wide_step — which already
// reads an inline Option's tag and pushes its payload — is run against that
// address. Both arms of every shape are here, because the tag decides which
// half of that step runs, and an Option inside a Result and a Result inside an
// Option are here because the two wrap each other.
package main

import std.io

struct Point { x: int, y: int }
struct Wrap { p: Point, tag: string }

fn main() {
    let money: Option<decimal> = some(1.25 as decimal)
    let no_money: Option<decimal> = none
    io.println("decimal {money} {no_money}")

    let here: Option<Point> = some(Point { x: 1, y: 2 })
    let gone: Option<Point> = none
    io.println("point {here} {gone}")

    let wrapped: Option<Wrap> = some(Wrap { p: Point { x: 3, y: 4 }, tag: "t" })
    io.println("wrap {wrapped}")

    let doubled: Option<Option<int>> = some(some(5))
    let hollow: Option<Option<int>> = some(none)
    let absent: Option<Option<int>> = none
    io.println("nested {doubled} {hollow} {absent}")

    let flags: Option<Option<bool>> = some(some(true))
    let rates: Option<Option<decimal>> = some(some(2.5 as decimal))
    let places: Option<Option<Point>> = some(some(Point { x: 9, y: 8 }))
    let deep: Option<Option<Option<int>>> = some(some(some(7)))
    io.println("more {flags} {rates} {places} {deep}")

    let good: Option<Result<int, string>> = some(ok(3))
    let bad: Option<Result<int, string>> = some(err("no"))
    let placed: Option<Result<Point, string>> = some(ok(Point { x: 1, y: 1 }))
    io.println("option-result {good} {bad} {placed}")

    let priced: Result<Option<decimal>, string> = ok(some(3.5 as decimal))
    let located: Result<Option<Point>, string> = ok(some(Point { x: 2, y: 2 }))
    let layered: Result<Option<Option<int>>, string> = ok(some(some(4)))
    let refused: Result<Option<Point>, string> = err("nope")
    io.println("result-option {priced} {located} {layered} {refused}")

    let places_list: List<Option<Point>> = [some(Point { x: 1, y: 1 }), none]
    io.println("list {places_list}")

    // the same values through show() rather than interpolation
    io.println("shown {here.or(Point { x: 0, y: 0 })} {places_list.len()}")
}
