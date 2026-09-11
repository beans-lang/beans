// A List buried inside another value compares by its elements, not by its
// address.
//
// A bare `xs == ys` has always been structural on both backends, because it
// goes through emit_list_equal and calls beans_list_equal. One level down it
// did not: emit_inline_equal fell through to the reference arm and compared
// the two list pointers, and request_value_eq — the comparator a map key or a
// list element thunk asks for — mapped List to kind "identity". So two values
// equal in every field answered `false` in a built binary and `true` under
// `beansc run`, at any depth, with no diagnostic on either side. The interpreter
// has always walked a list element by element wherever it meets one
// (tree_value_total_equal), so the native answer was the wrong one.
//
// Every shape that reaches that code is here: a struct field, a struct inside a
// struct, a list of records, a list of Options, an Option of a list, an Option
// and a Result holding a struct that holds a list, and nested lists themselves.
// Each shape appears equal AND unequal, and the unequal rows differ in the
// buried list rather than beside it, so a backend that went back to comparing
// addresses would answer `false` for the equal rows and still pass a diff that
// only had `false` in it.
//
// Two more shapes ride along because they are the same branch. A Map has no
// equality (spec/SYNTAX.md; the checker refuses a bare `m == n`), and a struct
// holding one used to be called equal to a copy of itself because both held the
// one map pointer — the interpreter answered false. And a Result, boxed or
// inline, was compared by address through a field for the same reason.
//
// The element kinds that need a comparator thunk are here too: a List<Bytes>
// and a List of payload enums each wrote `ptr @@.next.eq0` into the module —
// one `@` too many — so those two comparisons did not fail, they produced a
// module clang rejected.
package main

import std.io

struct Tail { tail: List<int> }
struct Nest { inner: Tail }
struct Point { x: int, y: int }
struct Points { inner: List<Point> }
struct Slots { inner: List<Option<int>> }
struct Held { slot: Option<List<int>> }
struct Answer { slot: Result<int, string> }
struct Counted { counts: Map<string, int> }

enum Tag {
    plain
    marked(n: int)
}

fn main() {
    io.println("tail {Tail { tail: [1, 2, 3] } == Tail { tail: [1, 2, 3] }} {Tail { tail: [1, 2, 3] } == Tail { tail: [1, 2, 4] }} {Tail { tail: [1, 2] } == Tail { tail: [1, 2, 3] }} {Tail { tail: [] } == Tail { tail: [] }}")
    io.println("nest {Nest { inner: Tail { tail: [7, 8] } } == Nest { inner: Tail { tail: [7, 8] } }} {Nest { inner: Tail { tail: [7, 8] } } == Nest { inner: Tail { tail: [7, 9] } }}")

    let left: Points = Points { inner: [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }] }
    let right: Points = Points { inner: [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }] }
    let apart: Points = Points { inner: [Point { x: 1, y: 2 }, Point { x: 3, y: 5 }] }
    io.println("records {left == right} {left == apart}")

    let slots: Slots = Slots { inner: [some(1), none, some(3)] }
    let slots_same: Slots = Slots { inner: [some(1), none, some(3)] }
    let slots_other: Slots = Slots { inner: [some(1), some(2), some(3)] }
    io.println("optionals {slots == slots_same} {slots == slots_other}")

    io.println("held {Held { slot: some([1, 2]) } == Held { slot: some([1, 2]) }} {Held { slot: some([1, 2]) } == Held { slot: some([1, 3]) }} {Held { slot: none } == Held { slot: none }} {Held { slot: none } == Held { slot: some([1, 2]) }}")

    let boxed: Option<List<int>> = some([4, 5])
    let boxed_same: Option<List<int>> = some([4, 5])
    let boxed_other: Option<List<int>> = some([4, 6])
    io.println("option {boxed == boxed_same} {boxed == boxed_other}")

    let carried: Result<Tail, string> = ok(Tail { tail: [9, 10] })
    let carried_same: Result<Tail, string> = ok(Tail { tail: [9, 10] })
    let carried_other: Result<Tail, string> = ok(Tail { tail: [9, 11] })
    let failed: Result<Tail, string> = err("no")
    let failed_same: Result<Tail, string> = err("no")
    io.println("result {carried == carried_same} {carried == carried_other} {carried == failed} {failed == failed_same}")

    let opts_a: List<Option<int>> = [some(1), none, some(3)]
    let opts_b: List<Option<int>> = [some(1), none, some(3)]
    let opts_c: List<Option<int>> = [some(1), some(2), some(3)]
    io.println("list-option {opts_a == opts_b} {opts_a == opts_c}")

    io.println("result-field {Answer { slot: ok(1) } == Answer { slot: ok(1) }} {Answer { slot: ok(1) } == Answer { slot: ok(2) }} {Answer { slot: err("x") } == Answer { slot: err("x") }} {Answer { slot: ok(1) } == Answer { slot: err("x") }}")

    let deep_a: List<List<int>> = [[1, 2], [3]]
    let deep_b: List<List<int>> = [[1, 2], [3]]
    let deep_c: List<List<int>> = [[1, 2], [4]]
    io.println("nested-lists {deep_a == deep_b} {deep_a == deep_c} {deep_a.contains([3])} {deep_a.contains([9])}")

    let decimals_a: List<decimal> = [1.5 as decimal, 2.25 as decimal]
    let decimals_b: List<decimal> = [1.5 as decimal, 2.25 as decimal]
    let decimals_c: List<decimal> = [1.5 as decimal, 2.5 as decimal]
    io.println("decimals {decimals_a == decimals_b} {decimals_a == decimals_c}")

    let bytes_a: List<Bytes> = [Bytes.from("hi"), Bytes.from("there")]
    let bytes_b: List<Bytes> = [Bytes.from("hi"), Bytes.from("there")]
    let bytes_c: List<Bytes> = [Bytes.from("hi"), Bytes.from("here")]
    io.println("bytes {bytes_a == bytes_b} {bytes_a == bytes_c}")

    let tags_a: List<Tag> = [Tag.plain, Tag.marked(1)]
    let tags_b: List<Tag> = [Tag.plain, Tag.marked(1)]
    let tags_c: List<Tag> = [Tag.plain, Tag.marked(2)]
    io.println("enums {tags_a == tags_b} {tags_a == tags_c}")

    // A map is equal to nothing, itself included, so a struct holding one is
    // never equal to another — not even to itself, which is the row that
    // caught the identity compare: both sides were the one map pointer.
    let counted: Counted = Counted { counts: {} }
    io.println("maps {counted == counted} {Counted { counts: {} } == Counted { counts: {} }}")
}
