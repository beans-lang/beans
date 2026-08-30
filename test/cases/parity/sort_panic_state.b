// A collection operation interrupted by a panicking callback leaves the
// collection exactly as it was before the call — same contents, same order —
// and both backends print the byte-identical result (issue #73,
// spec/CONCURRENCY.md). And with no panic at all, both backends run the same
// bottom-up stable merge, so a predicate that is not a strict weak ordering
// (always-true, a rock-paper-scissors tournament) still produces one agreed
// order: the interpreter once ran an insertion sort, which gives a different
// permutation for exactly those predicates.
//
// Shapes: the slot merge at n = 2, 3, 12 and 40 (several merge passes), a
// narrow-stride List<i32> (the widened copy path), List<decimal> and a
// List of inline structs (the decv and val merges), sort_by_key with the key
// panicking at the first call, in the middle and at the last, and one whose
// key span forces more than one radix pass natively.
import std.io

struct Pair {
    a: int
    b: int
}

class Store {
    pub static ints: List<int> = []
    pub static narrow: List<i32> = []
    pub static floats: List<f32> = []
    pub static decs: List<decimal> = []
    pub static pairs: List<Pair> = []
    pub static seen: List<string> = []
}

fn boom() -> bool {
    let empty: List<int> = []
    return empty[0] == 1
}

fn boomk() -> int {
    let empty: List<int> = []
    return empty[0]
}

fn show_ints(tag: string) {
    var line: string = ""
    var total: int = 0
    for x: int in Store.ints {
        line = "{line} {x}"
        total += x
    }
    io.println("{tag} len={Store.ints.len()} sum={total}:{line}")
}

fn show_narrow(tag: string) {
    var line: string = ""
    for x: i32 in Store.narrow { line = "{line} {x}" }
    io.println("{tag}:{line}")
}

fn show_decs(tag: string) {
    var line: string = ""
    for x: decimal in Store.decs { line = "{line} {x}" }
    io.println("{tag}:{line}")
}

fn show_pairs(tag: string) {
    var line: string = ""
    for p: Pair in Store.pairs { line = "{line} {p.a}/{p.b}" }
    io.println("{tag}:{line}")
}

fn panicky(a: int, b: int) -> bool {
    if a == 9 || b == 9 { return boom() }
    return a < b
}

fn sort_ints() -> int {
    Store.ints.sort_by(fn(a: int, b: int) -> bool { return panicky(a, b) })
    return 0
}

fn sort_narrow() -> int {
    Store.narrow.sort_by(fn(a: i32, b: i32) -> bool {
        if a == 9 || b == 9 { return boom() }
        return a < b
    })
    return 0
}

fn sort_decs() -> int {
    Store.decs.sort_by(fn(a: decimal, b: decimal) -> bool {
        if a == 9.5 || b == 9.5 { return boom() }
        return a < b
    })
    return 0
}

fn sort_pairs() -> int {
    Store.pairs.sort_by(fn(x: Pair, y: Pair) -> bool {
        if x.a == 9 || y.a == 9 { return boom() }
        return x.a < y.a
    })
    return 0
}

fn key_first() -> int {
    Store.ints.sort_by_key(fn(a: int) -> int { return boomk() })
    return 0
}

fn key_mid() -> int {
    Store.ints.sort_by_key(fn(a: int) -> int {
        if a == 2 { return boomk() }
        return a
    })
    return 0
}

fn key_last() -> int {
    Store.ints.sort_by_key(fn(a: int) -> int {
        if a == 12 { return boomk() }
        return a
    })
    return 0
}

fn key_wide() -> int {
    Store.ints.sort_by_key(fn(a: int) -> int {
        if a == 12 { return boomk() }
        return a * 100000
    })
    return 0
}

fn grow_under_sort() -> int {
    Store.ints.sort_by(fn(a: int, b: int) -> bool {
        Store.ints.push(99)
        return a < b
    })
    return 0
}

fn shrink_under_sort() -> int {
    Store.ints.sort_by(fn(a: int, b: int) -> bool {
        if Store.ints.len() > 2 { Store.ints.remove(0) }
        return a < b
    })
    return 0
}

fn grow_under_keyed_sort() -> int {
    Store.ints.sort_by_key(fn(a: int) -> int {
        Store.ints.push(77)
        return 0 - a
    })
    return 0
}

fn run(which: int) -> int {
    if which == 1 { return sort_ints() }
    if which == 2 { return sort_narrow() }
    if which == 3 { return sort_decs() }
    if which == 4 { return sort_pairs() }
    if which == 5 { return key_first() }
    if which == 6 { return key_mid() }
    if which == 7 { return key_wide() }
    if which == 9 { return grow_under_sort() }
    if which == 10 { return shrink_under_sort() }
    if which == 11 { return grow_under_keyed_sort() }
    return key_last()
}

fn shield(which: int, tag: string) {
    let child: Brew<int> = brew run(which)
    match child.join() {
        ok(v) => { io.println("{tag}: ok") }
        err(problem) => { io.println("{tag}: {problem.kind}") }
    }
}

fn set_ints(n: int) {
    Store.ints = []
    // 9 first so every n contains the trigger; the rest descend
    Store.ints.push(9)
    var i: int = n - 1
    for i > 0 {
        Store.ints.push(i)
        i -= 1
    }
}

// A comparator that reads the list it is sorting, through a captured
// reference, sees the same intermediate states on both backends: each
// merged block is committed when it completes — on the list's own slots,
// and mirrored block for block when the sort runs over a widened copy
// (List<f32>, the one slot-sorted element with 4-byte storage).
fn view_ints() -> string {
    var line: string = ""
    for x: int in Store.ints { line = "{line}{x}" }
    return line
}
fn view_floats() -> string {
    var line: string = ""
    for x: f32 in Store.floats { line = "{line}{x}" }
    return line
}
fn observe_ints() -> int {
    Store.ints.sort_by(fn(a: int, b: int) -> bool {
        Store.seen.push(view_ints())
        return a < b
    })
    return 0
}
fn observe_floats() -> int {
    Store.floats.sort_by(fn(a: f32, b: f32) -> bool {
        Store.seen.push(view_floats())
        return a < b
    })
    return 0
}
fn observe_panic() -> int {
    Store.floats.sort_by(fn(a: f32, b: f32) -> bool {
        Store.seen.push(view_floats())
        if a == 9.0 || b == 9.0 { return boom() }
        return a < b
    })
    return 0
}
fn run_observer(which: int) -> int {
    if which == 1 { return observe_ints() }
    if which == 2 { return observe_floats() }
    return observe_panic()
}
fn shield_observer(which: int, tag: string) {
    let child: Brew<int> = brew run_observer(which)
    match child.join() {
        ok(v) => { io.println("{tag}: ok") }
        err(problem) => { io.println("{tag}: {problem.kind}") }
    }
    io.println("{tag} views: {Store.seen.join(" ")}")
    Store.seen = []
}
fn main() {
    // interrupted sorts restore, at n = 2, 3, 12, 40
    for n: int in [2, 3, 12, 40] {
        set_ints(n)
        shield(1, "rec n={n}")
        show_ints("ints n={n}")
    }
    Store.ints = [5, 3, 9, 1, 7, 2, 8, 4, 6, 0, 11, 12]
    shield(1, "ints")
    show_ints("ints")
    Store.narrow = [5, 3, 9, 1, 7, 2, 8, 4, 6, 0, 11, 12]
    shield(2, "narrow")
    show_narrow("narrow")
    Store.decs = [5.5, 3.5, 9.5, 1.5]
    shield(3, "decs")
    show_decs("decs")
    Store.pairs = [Pair { a: 5, b: 1 }, Pair { a: 9, b: 2 }, Pair { a: 3, b: 3 }]
    shield(4, "pairs")
    show_pairs("pairs")
    shield(5, "key first")
    show_ints("key-first")
    shield(6, "key mid")
    show_ints("key-mid")
    shield(8, "key last")
    show_ints("key-last")
    shield(7, "key wide")
    show_ints("key-wide")
    // no panic: predicates that are not strict weak orderings still agree
    var one: List<int> = [2, 1, 3]
    one.sort_by(fn(x: int, y: int) -> bool { return true })
    var line: string = ""
    for x: int in one { line = "{line} {x}" }
    io.println("always-true:{line}")
    var rps: List<int> = [3, 1, 2, 1, 3, 2, 3, 1]
    rps.sort_by(fn(x: int, y: int) -> bool {
        if x == 1 && y == 2 { return true }
        if x == 2 && y == 3 { return true }
        if x == 3 && y == 1 { return true }
        return false
    })
    line = ""
    for x: int in rps { line = "{line} {x}" }
    io.println("tournament:{line}")
    // and a completed sort still sorts
    Store.ints = [5, 3, 1, 7, 2, 8, 4, 6, 0, 11, 12]
    Store.ints.sort_by(fn(a: int, b: int) -> bool { return a < b })
    show_ints("sorted")
    Store.ints.sort_by_key(fn(a: int) -> int { return 0 - a })
    show_ints("by-key-desc")
    Store.ints = [4, 2, 3, 1]
    shield_observer(1, "observed ints")
    show_ints("observed ints after")
    Store.floats = [4.0, 2.0, 3.0, 1.0]
    shield_observer(2, "observed floats")
    io.println("observed floats after: {view_floats()}")
    Store.floats = [4.0, 9.0, 2.0, 1.0]
    shield_observer(3, "observed floats panic")
    io.println("observed floats panic after: {view_floats()}")
    // A callback structurally changing the list it is sorting is refused
    // as the program's own panic, on both engines, at the first callback
    // return after the change — the sort would otherwise permute stale
    // storage (a use-after-free on growth, reads past the end on shrink).
    // The list stays as the mutation left it; there is nothing coherent
    // to restore.
    Store.ints = [8, 7, 6, 5, 4, 3, 2, 1]
    shield(9, "grow under sort")
    show_ints("grow under sort after")
    Store.ints = [8, 7, 6, 5, 4, 3, 2, 1]
    shield(10, "shrink under sort")
    show_ints("shrink under sort after")
    Store.ints = [3, 1, 2, 5, 4, 7, 6, 8]
    shield(11, "grow under keyed sort")
    show_ints("grow under keyed sort after")
}
