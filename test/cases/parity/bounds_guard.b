// Counted loops whose index checks one test before the loop can answer
// (analyze_bounds_guards, src/mir.b). Where that test fails, the original
// checks still run: a loop that walks off the end panics at the same index,
// with the same message, after the same stores, under every backend. The
// edges here are the ones the test has to get right: the last index, an
// offset below zero, a start below zero, a step big enough to wrap the
// counter, a loop that never runs, and a counter read after its own step.
package main

import std.io

fn fill(xs: List<int>, start: int, limit: int, step: int, base: int) -> int {
    var j: int = start
    for j < limit {
        xs[base + j] = j
        j += step
    }
    return j
}

fn total(xs: List<int>, limit: int, base: int) -> int {
    var sum: int = 0
    var j: int = 0
    for j < limit {
        sum += xs[j - base]
        j += 1
    }
    return sum
}

// The counter is read after it steps, so this index is not `base + counter`
// for a counter the head has checked: it must stay checked.
fn ahead(xs: List<int>, limit: int) -> int {
    var sum: int = 0
    var j: int = 0
    for j < limit {
        j += 1
        sum += xs[j]
    }
    return sum
}

fn mark(bytes: Bytes, start: int, limit: int, step: int) -> int {
    var j: int = start
    for j < limit {
        bytes[j] = 7
        bytes.set(j, bytes[j] + 1)
        j += step
    }
    var count: int = 0
    var k: int = 0
    for k < limit {
        count += bytes.get(k).or(0)
        k += 1
    }
    return count
}

fn multiply(a: List<float>, b: List<float>, c: List<float>, n: int) -> float {
    var i: int = 0
    for i < n {
        var k: int = 0
        for k < n {
            let aik: float = a[i * n + k]
            var j: int = 0
            for j < n {
                c[i * n + j] = c[i * n + j] + aik * b[k * n + j]
                j += 1
            }
            k += 1
        }
        i += 1
    }
    var sum: float = 0.0
    for v: float in c { sum += v }
    return sum
}

fn show(xs: List<int>) -> string {
    var text: string = ""
    for x: int in xs { text = "{text} {x}" }
    return text
}

fn zeros(n: int) -> List<int> {
    var xs: List<int> = []
    var i: int = 0
    for i < n {
        xs.push(0)
        i += 1
    }
    return move xs
}

fn main() {
    let max: int = 9223372036854775807
    var xs: List<int> = zeros(6)
    match contained fill(xs, 0, 6, 1, 0) {
        ok(end) => io.println("in range, ended at {end}:{show(xs)}"),
        err(e) => io.println("in range: {e.msg}"),
    }
    xs = zeros(6)
    match contained fill(xs, 0, 9, 1, 0) {
        ok(end) => io.println("past the end ended at {end}"),
        err(e) => io.println("past the end: {e.msg}; kept:{show(xs)}"),
    }
    xs = zeros(6)
    match contained fill(xs, 0, 4, 1, 3) {
        ok(end) => io.println("offset ended at {end}"),
        err(e) => io.println("offset: {e.msg}; kept:{show(xs)}"),
    }
    xs = zeros(6)
    match contained fill(xs, 0, 3, 1, -1) {
        ok(end) => io.println("offset below zero ended at {end}"),
        err(e) => io.println("offset below zero: {e.msg}; kept:{show(xs)}"),
    }
    xs = zeros(6)
    match contained fill(xs, -2, 3, 1, 0) {
        ok(end) => io.println("start below zero ended at {end}"),
        err(e) => io.println("start below zero: {e.msg}; kept:{show(xs)}"),
    }
    xs = zeros(6)
    match contained fill(xs, 1, 6, max, 0) {
        ok(end) => io.println("wrapping step ended at {end}"),
        err(e) => io.println("wrapping step: {e.msg}; kept:{show(xs)}"),
    }
    xs = zeros(6)
    match contained fill(xs, 1, 6, 0 - 1, 0) {
        ok(end) => io.println("backward step ended at {end}"),
        err(e) => io.println("backward step: {e.msg}; kept:{show(xs)}"),
    }
    xs = zeros(6)
    match contained fill(xs, 0, 6, 2, 0) {
        ok(end) => io.println("step two ended at {end}:{show(xs)}"),
        err(e) => io.println("step two: {e.msg}"),
    }
    xs = zeros(6)
    match contained fill(xs, 7, 3, 1, 100) {
        ok(end) => io.println("never runs, ended at {end}:{show(xs)}"),
        err(e) => io.println("never runs: {e.msg}"),
    }
    let ys: List<int> = [1, 2, 3, 4, 5, 6]
    match contained total(ys, 6, 0) {
        ok(sum) => io.println("total {sum}"),
        err(e) => io.println("total: {e.msg}"),
    }
    match contained total(ys, 6, 1) {
        ok(sum) => io.println("total shifted {sum}"),
        err(e) => io.println("total shifted: {e.msg}"),
    }
    match contained ahead(ys, 5) {
        ok(sum) => io.println("ahead {sum}"),
        err(e) => io.println("ahead: {e.msg}"),
    }
    match contained ahead(ys, 6) {
        ok(sum) => io.println("ahead to the end {sum}"),
        err(e) => io.println("ahead to the end: {e.msg}"),
    }
    var bytes: Bytes = new Bytes(10)
    match contained mark(bytes, 1, 10, 3) {
        ok(count) => io.println("marked {count}"),
        err(e) => io.println("marked: {e.msg}"),
    }
    match contained mark(bytes, 0, 12, 5) {
        ok(count) => io.println("marked past the end {count}"),
        err(e) => io.println("marked past the end: {e.msg}; byte 5 is {bytes[5]}"),
    }
    let n: int = 4
    var a: List<float> = []
    var b: List<float> = []
    var c: List<float> = []
    var i: int = 0
    for i < n * n {
        a.push((i % 5) as float)
        b.push((i % 3) as float)
        c.push(1.0)
        i += 1
    }
    match contained multiply(a, b, c, n) {
        ok(sum) => io.println("multiply {sum}"),
        err(e) => io.println("multiply: {e.msg}"),
    }
    match contained multiply(a, b, c, n + 1) {
        ok(sum) => io.println("multiply too wide {sum}"),
        err(e) => io.println("multiply too wide: {e.msg}"),
    }
}
