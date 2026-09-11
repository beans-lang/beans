// A map key wider than one runtime slot.
//
// map_key_kind answers 4 — "custom structural" — for every wide inline value,
// and the runtime then needs two symbols with it: an equality thunk and a hash
// thunk. request_wide_eq and request_wide_hash had no shape for a Result, so
// both answered the empty string, and every caller interpolated that answer
// straight into the runtime call. The module carried `ptr , ptr )` and the
// build failed talking about a .ll file — not a refusal, malformed output.
//
// Every map operation reaches those two symbols, so every one of them is here:
// the literal, a set through `m[k] = v`, insert, get through `m[k]`, get()
// answering an Option, contains_key, remove, len, and keys()/values(). The ok
// and err arms both key rows, and both arms carry a wide payload in one of the
// maps, because the comparator only ever reads the arm the tag selects — the
// dead arm of an inline Result is zeroed, and reading it would dereference
// null.
//
// The hash has to agree with the equality or the map breaks quietly: two keys
// that compare equal must land in one bucket. That is what the reads below
// check, and why each map is read back by a freshly built key rather than by
// the one that was stored.
//
// Iteration order is not a promise a plain Map makes, so the key lists are
// sorted before they are printed.
package main

import std.io

struct Point { x: int, y: int }

fn main() {
    var by_result: Map<Result<int, string>, string> = {
        ok(1): "one",
        err("bad"): "oops",
    }
    by_result[ok(2)] = "two"
    io.println("insert {by_result.insert(ok(3), "three")} {by_result.insert(ok(3), "again")}")
    io.println("len {by_result.len()}")
    io.println("index {by_result[ok(1)]} {by_result[ok(2)]} {by_result[err("bad")]}")
    io.println("has {by_result.contains_key(ok(1))} {by_result.contains_key(ok(9))} {by_result.contains_key(err("bad"))} {by_result.contains_key(err("other"))}")
    io.println("get {by_result.get(ok(3))} {by_result.get(ok(4))}")
    io.println("remove {by_result.remove(ok(1))} {by_result.remove(ok(1))} {by_result.len()}")

    var by_option: Map<Option<Point>, int> = {}
    by_option[some(Point { x: 1, y: 2 })] = 5
    by_option[none] = 7
    by_option[some(Point { x: 3, y: 4 })] = 9
    io.println("option {by_option.len()} {by_option[some(Point { x: 1, y: 2 })]} {by_option[none]} {by_option.contains_key(some(Point { x: 1, y: 9 }))}")

    var wide_arms: Map<Result<Point, string>, int> = {}
    wide_arms[ok(Point { x: 3, y: 4 })] = 1
    wide_arms[err("gone")] = 2
    io.println("wide {wide_arms[ok(Point { x: 3, y: 4 })]} {wide_arms[err("gone")]} {wide_arms.contains_key(ok(Point { x: 3, y: 5 }))} {wide_arms.contains_key(err("other"))}")

    var by_struct: Map<Point, string> = {}
    by_struct[Point { x: 1, y: 1 }] = "a"
    by_struct[Point { x: 2, y: 2 }] = "b"
    var names: List<string> = by_struct.values()
    names.sort()
    io.println("struct {by_struct.len()} {names}")

    // an ordered map keeps insertion order, so this one can print its keys
    var ordered: OrderedMap<Result<int, string>, int> = {}
    ordered[ok(10)] = 1
    ordered[err("x")] = 2
    ordered[ok(20)] = 3
    var shown: List<string> = []
    for key: Result<int, string> in ordered.keys() {
        shown.push("{key}={ordered[key]}")
    }
    io.println("ordered {shown}")
}
