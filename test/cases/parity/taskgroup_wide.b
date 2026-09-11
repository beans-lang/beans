// A TaskGroup whose children answer something wider than one runtime slot.
//
// The group itself has always taken wide payloads — brew goes through
// beans_taskgroup_brew_typed and wait_all collects through
// beans_taskgroup_collect_typed — but reading one row back did not. next() and
// try_next() answer Option<Result<T>>, and for a wide T the Result is the
// inline {i1, T, Error} aggregate and the Option is an aggregate in turn, so
// neither the nullable-pointer Option nor the boxed Result the emitter built
// could carry it: the build refused, and a dynamic fleet returning a struct, an
// Option, a Result or a decimal ran interpreted and would not build.
//
// Delivery is in completion order, which is not a promise about which row
// arrives first, so every row below is folded into an order-independent answer.
// The err arm is here too — a panicking child is how a wide-payload row becomes
// a failure — because it is the other half of the aggregate this builds.
package main

import std.io

struct Point { x: int, y: int }
struct Mixed { slot: Option<int>, tail: List<int> }

fn a_point(n: int) -> Point { return Point { x: n, y: n * 2 } }
fn a_mixed(n: int) -> Mixed { return Mixed { slot: some(n), tail: [n, n + 1] } }
fn an_option(n: int) -> Option<int> {
    if n == 2 { return none }
    return some(n)
}
fn an_option_point(n: int) -> Option<Point> {
    if n == 2 { return none }
    return some(Point { x: n, y: n })
}
fn a_nested_option(n: int) -> Option<Option<int>> {
    if n == 2 { return some(none) }
    return some(some(n))
}
fn a_result(n: int) -> Result<int, string> {
    if n == 2 { return err("two") }
    return ok(n)
}
fn a_result_point(n: int) -> Result<Point, string> {
    if n == 2 { return err("two") }
    return ok(Point { x: n, y: n })
}
fn a_decimal(n: int) -> decimal { return (n as decimal) / (4 as decimal) }
fn risky(n: int) -> Point {
    if n == 2 { panic("child {n} failed") }
    return Point { x: n, y: n }
}

fn points() {
    let group: TaskGroup<Point> = new TaskGroup<Point>()
    for n: int in 1..4 { group.brew(a_point(n)) }
    var total: int = 0
    var rows: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(p) => { total = total + p.x + p.y; rows = rows + 1 }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("point rows={rows} total={total}")
}

fn mixed() {
    let group: TaskGroup<Mixed> = new TaskGroup<Mixed>()
    for n: int in 1..4 { group.brew(a_mixed(n)) }
    var total: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(m) => { total = total + m.slot.or(0) + m.tail.len() }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("mixed total={total}")
}

fn options() {
    let group: TaskGroup<Option<int>> = new TaskGroup<Option<int>>()
    for n: int in 1..4 { group.brew(an_option(n)) }
    var total: int = 0
    var empties: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(v) => {
                        match v {
                            some(x) => { total = total + x }
                            none => { empties = empties + 1 }
                        }
                    }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("option total={total} empties={empties}")
}

fn option_points() {
    let group: TaskGroup<Option<Point>> = new TaskGroup<Option<Point>>()
    for n: int in 1..4 { group.brew(an_option_point(n)) }
    var total: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(v) => {
                        match v {
                            some(p) => { total = total + p.x }
                            none => { total = total + 100 }
                        }
                    }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("option-point total={total}")
}

fn nested_options() {
    let group: TaskGroup<Option<Option<int>>> =
        new TaskGroup<Option<Option<int>>>()
    for n: int in 1..4 { group.brew(a_nested_option(n)) }
    var total: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(v) => {
                        match v {
                            some(inner) => { total = total + inner.or(50) }
                            none => { total = total + 1000 }
                        }
                    }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("nested-option total={total}")
}

fn results() {
    let group: TaskGroup<Result<int, string>> =
        new TaskGroup<Result<int, string>>()
    for n: int in 1..4 { group.brew(a_result(n)) }
    var total: int = 0
    var refused: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(v) => {
                        match v {
                            ok(x) => { total = total + x }
                            err(text) => { refused = refused + text.len() }
                        }
                    }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("result total={total} refused={refused}")
}

fn result_points() {
    let group: TaskGroup<Result<Point, string>> =
        new TaskGroup<Result<Point, string>>()
    for n: int in 1..4 { group.brew(a_result_point(n)) }
    var total: int = 0
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(v) => {
                        match v {
                            ok(p) => { total = total + p.x }
                            err(text) => { total = total + text.len() }
                        }
                    }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("result-point total={total}")
}

fn decimals() {
    let group: TaskGroup<decimal> = new TaskGroup<decimal>()
    for n: int in 1..4 { group.brew(a_decimal(n)) }
    var total: decimal = 0.0 as decimal
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(d) => { total = total + d }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => { break }
        }
    }
    io.println("decimal total={total}")
}

fn failures() {
    let group: TaskGroup<Point> = new TaskGroup<Point>()
    for n: int in 1..4 { group.brew(risky(n)) }
    var good: int = 0
    var kinds: List<string> = []
    for true {
        match group.next() {
            some(row) => {
                match row {
                    ok(p) => { good = good + p.x }
                    err(problem) => { kinds.push(problem.kind) }
                }
            }
            none => { break }
        }
    }
    kinds.sort()
    io.println("failures good={good} kinds={kinds}")
}

// try_next takes the same aggregate path next() does and answers `none` for
// "nothing ready yet" as well as for "nothing left", so a fleet is drained by
// spinning on it until every row has been seen. Three children, three rows.
fn polled() {
    let group: TaskGroup<Option<Point>> = new TaskGroup<Option<Point>>()
    for n: int in 1..4 { group.brew(an_option_point(n)) }
    var seen: int = 0
    var total: int = 0
    for seen < 3 {
        match group.try_next() {
            some(row) => {
                seen = seen + 1
                match row {
                    ok(v) => {
                        match v {
                            some(p) => { total = total + p.x }
                            none => { total = total + 100 }
                        }
                    }
                    err(problem) => { io.println("unexpected {problem.msg}") }
                }
            }
            none => {}
        }
    }
    io.println("try-next rows={seen} total={total}")
}

fn collected() {
    let group: TaskGroup<Point> = new TaskGroup<Point>()
    for n: int in 1..4 { group.brew(a_point(n)) }
    match group.wait_all() {
        ok(all) => {
            var total: int = 0
            for p: Point in all { total = total + p.x + p.y }
            io.println("wait_all rows={all.len()} total={total}")
        }
        err(problem) => { io.println("wait_all err {problem.kind}") }
    }
}

fn main() {
    points()
    mixed()
    options()
    option_points()
    nested_options()
    results()
    result_points()
    decimals()
    polled()
    failures()
    collected()
}
