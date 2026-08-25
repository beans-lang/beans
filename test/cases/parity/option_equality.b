// `Option<T>` compared by value, where T is a reference.
//
// A niche-encoded Option — one whose payload is a reference — is stored as a
// bare pointer, so the emitter's "is this a reference?" test answered true for
// the Option itself and compared two payloads by address. `Option<string>`
// then reported false for equal strings living at different addresses, and so
// did every struct carrying such a field. No error, no diagnostic, just a
// different answer from the one `beansc run` gives. It was in shipped 0.1.32.
//
// The strings here are deliberately built by slicing rather than written as
// literals: two identical literals may share one allocation, and comparing
// those by address happens to give the right answer, which is exactly how a
// bug like this hides from a test.
package main

import std.io

struct Entry {
    key: string
    value: Option<string> = none
}

class Node {
    pub v: int

    fn init(v: int) { self.v = v }
}

fn main() {
    let source: string = "xbar"
    let sliced: string = source.slice(1, 4)
    let literal: string = "bar"
    io.println("strings {sliced == literal}")

    let left: Option<string> = some(sliced)
    let right: Option<string> = some(literal)
    let missing: Option<string> = none
    let also_missing: Option<string> = none
    io.println("option {left == right} {left == missing} {missing == also_missing}")

    // the same thing one level in, which is where it was found
    let a: Entry = Entry { key: "foo", value: some(sliced) }
    let b: Entry = Entry { key: "foo", value: some(literal) }
    let c: Entry = Entry { key: "foo" }
    let d: Entry = Entry { key: "foo" }
    io.println("record {a == b} {a == c} {c == d}")

    // and through a list, the way a parsed context is compared
    var xs: List<Entry> = [Entry { key: "baz" }, Entry { key: "foo", value: some(sliced) }]
    var ys: List<Entry> = [Entry { key: "baz" }, Entry { key: "foo", value: some(literal) }]
    io.println("list {xs == ys}")

    // an Option holding a class still compares by identity
    let shared: Node = new Node(1)
    let one: Option<Node> = some(shared)
    let same: Option<Node> = some(shared)
    let other: Option<Node> = some(new Node(1))
    io.println("class {one == same} {one == other}")
}
