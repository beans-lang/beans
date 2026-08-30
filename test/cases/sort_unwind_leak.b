// A contained panic that unwinds through a runtime frame frees what the
// frame held and leaves the collection it was permuting exactly as it was
// (issue #73, spec/CONCURRENCY.md). Every runtime frame that hosts a Beans
// callback while holding scratch is hit here, one hundred times each, under
// the driver's ASan build and the macOS BEANS_NO_POOL leaks sweep: the merge
// scratch of the slot, narrow-stride, decimal and inline-struct sorts, the
// key/count/value buffers of sort_by_key (a panic at the first, a middle and
// the last key call, and a key span wide enough for more than one radix
// pass), and the spilled argument arrays of a reflective call past its
// eight-argument stack arity. A single leaked buffer is a hundred blocks.
// Each round also checks the list still starts with its original first two
// elements: a permutation left behind would print STATE WRONG and fail the
// marker grep.
import std.io
import std.reflect

struct Pair {
    a: int
    b: int
}

class Store {
    pub static ints: List<int> = []
    pub static narrow: List<i32> = []
    pub static decs: List<decimal> = []
    pub static pairs: List<Pair> = []
}

fn boom() -> bool {
    let empty: List<int> = []
    return empty[0] == 1
}

fn boomk() -> int {
    let empty: List<int> = []
    return empty[0]
}

pub fn wide9(a: int, b: int, c: int, d: int, e: int, f: int, g: int, h: int,
         i: int) -> int {
    let empty: List<int> = []
    return empty[a + b + c + d + e + f + g + h + i]
}

fn s_ints() -> int {
    Store.ints.sort_by(fn(a: int, b: int) -> bool {
        if a == 9 || b == 9 { return boom() }
        return a < b
    })
    return 0
}

fn s_narrow() -> int {
    Store.narrow.sort_by(fn(a: i32, b: i32) -> bool {
        if a == 9 || b == 9 { return boom() }
        return a < b
    })
    return 0
}

fn s_decs() -> int {
    Store.decs.sort_by(fn(a: decimal, b: decimal) -> bool {
        if a == 9.5 || b == 9.5 { return boom() }
        return a < b
    })
    return 0
}

fn s_pairs() -> int {
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

fn reflect_spill() -> int {
    let wide: reflect.Function =
        reflect.find_function("main.wide9").expect("wide9")
    match wide.call([
        reflect.value(1), reflect.value(2), reflect.value(3),
        reflect.value(4), reflect.value(5), reflect.value(6),
        reflect.value(7), reflect.value(8), reflect.value(9)]) {
        ok(v) => { return 1 }
        err(e) => { return 2 }
    }
}

fn run(which: int) -> int {
    if which == 1 { return s_ints() }
    if which == 2 { return s_narrow() }
    if which == 3 { return s_decs() }
    if which == 4 { return s_pairs() }
    if which == 5 { return key_first() }
    if which == 6 { return key_mid() }
    if which == 7 { return key_wide() }
    if which == 8 { return key_last() }
    return reflect_spill()
}

fn shield(which: int) -> bool {
    let child: Brew<int> = brew run(which)
    match child.join() {
        ok(v) => { return false }
        err(problem) => { return true }
    }
}

fn intact() -> bool {
    return Store.ints[0] == 5 && Store.ints[1] == 3 &&
           Store.narrow[0] == 5 && Store.narrow[1] == 3 &&
           Store.decs[0] == 5.5 && Store.pairs[0].a == 5
}

fn main() {
    Store.ints = [5, 3, 9, 1, 7, 2, 8, 4, 6, 0, 11, 12]
    Store.narrow = [5, 3, 9, 1, 7, 2, 8, 4, 6, 0, 11, 12]
    Store.decs = [5.5, 3.5, 9.5, 1.5]
    Store.pairs = [Pair { a: 5, b: 1 }, Pair { a: 9, b: 2 }, Pair { a: 3, b: 3 }]
    var caught: int = 0
    var round: int = 0
    for round < 100 {
        var which: int = 1
        for which <= 9 {
            if shield(which) { caught += 1 }
            if !intact() {
                io.println("STATE WRONG after shape {which}")
                return
            }
            which += 1
        }
        round += 1
    }
    io.println("sorted under panic {caught}")
}
