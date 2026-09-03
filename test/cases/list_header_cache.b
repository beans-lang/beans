// A loop the emitter proved private keeps its list's header in registers
// (src/mir.b, analyze_list_header_cache). Every claim that proof makes is
// observable from a program, and this is the program.
//
// Sizes are deliberately past a list's first reallocation: a list starts at
// capacity 4, so 5, 17 and 300 all cross a grow, which is the one edge where
// the cached data pointer and capacity go stale and have to be read back.
// Cases built from one element or two literals prove nothing here.
import std.io

struct Point { x: int, y: int }

class Counter {
    n: int
    fn init(n: int) { self.n = n }
}

fn doubled(n: int) -> int { return n * 2 }

// The headline shape: push in a loop, then read every slot back. A data
// pointer left stale across a grow writes into freed memory and this is
// where it shows.
fn push_and_read() {
    var xs: List<int> = []
    var i: int = 0
    for i < 17 { xs.push(i * 3) ; i += 1 }
    var sum: int = 0
    var j: int = 0
    for j < xs.len() { sum += xs[j] ; j += 1 }
    io.println("push_and_read len={xs.len()} first={xs[0]} last={xs[16]} sum={sum}")
}

// pop reads the same three fields and moves the same change word.
fn drain() {
    var xs: List<int> = []
    var i: int = 0
    for i < 40 { xs.push(i) ; i += 1 }
    var total: int = 0
    for xs.len() > 0 {
        match xs.pop() {
            some(v) => { total += v }
            none => { break }
        }
    }
    io.println("drain total={total} len={xs.len()}")
}

fn drain_is_empty() {
    var xs: List<int> = [3, 1, 4, 1, 5, 9, 2, 6]
    var total: int = 0
    for !xs.is_empty() {
        match xs.pop() {
            some(v) => { total += v }
            none => { break }
        }
    }
    io.println("drain_is_empty total={total} len={xs.len()}")
}

// An element store aliases nothing the cache holds, which is the whole
// claim: index writes and reads have to keep agreeing with it.
fn index_writes() {
    var xs: List<int> = [0, 0, 0, 0, 0, 0, 0]
    var i: int = 0
    for i < xs.len() { xs[i] = i * i ; i += 1 }
    var sum: int = 0
    var j: int = 0
    for j < xs.len() { sum += xs[j] ; j += 1 }
    io.println("index_writes sum={sum} at6={xs[6]}")
}

// push, index write and pop in one body: the length the cache carries has to
// stay right for all three at once.
fn interleaved() {
    var xs: List<int> = []
    var i: int = 0
    for i < 30 {
        xs.push(i)
        if i % 5 == 0 {
            match xs.pop() {
                some(v) => { xs.push(v * 2) }
                none => {}
            }
        }
        xs[xs.len() - 1] = xs[xs.len() - 1] + 1
        i += 1
    }
    var sum: int = 0
    var j: int = 0
    for j < xs.len() { sum += xs[j] ; j += 1 }
    io.println("interleaved len={xs.len()} sum={sum} at0={xs[0]} at29={xs[29]}")
}

// Leaving the loop early is an edge like any other, and the write-back rides
// the edge: the length read after the break, and the one read after the
// return, both have to be the length the loop actually reached.
fn broke_out() -> int {
    var xs: List<int> = []
    var i: int = 0
    for i < 100 {
        xs.push(i)
        if i == 12 { break }
        i += 1
    }
    return xs.len()
}

fn returned_early(limit: int) -> int {
    var xs: List<int> = []
    var i: int = 0
    for i < 100 {
        xs.push(i)
        if i == limit { return xs.len() }
        i += 1
    }
    return -1
}

// A nested loop over the same list is covered by the outer one's cache; the
// two must not open a second one over a header the first has not published.
fn nested() {
    var xs: List<int> = []
    var i: int = 0
    for i < 7 {
        var j: int = 0
        for j < 5 { xs.push(i * 10 + j) ; j += 1 }
        i += 1
    }
    io.println("nested len={xs.len()} at0={xs[0]} at34={xs[34]}")
}

// The change word is what a list loop compares. A cached loop accumulates it
// in a register, so the count the next iteration snapshots is only right if
// the write-back is exact.
fn iterate_after() {
    var xs: List<int> = []
    var i: int = 0
    for i < 9 { xs.push(i) ; i += 1 }
    var total: int = 0
    for x: int in xs { total += x }
    var again: int = 0
    for x: int in xs { again += x * 2 }
    io.println("iterate_after total={total} again={again}")
}

// A call in the body cannot reach a list nothing handed it, so the cache
// stays open across one.
fn calls_inside() {
    var xs: List<int> = []
    var i: int = 0
    for i < 33 { xs.push(doubled(i)) ; i += 1 }
    io.println("calls_inside len={xs.len()} at32={xs[32]}")
}

fn two_lists() {
    var a: List<int> = []
    var b: List<int> = []
    var i: int = 0
    for i < 25 { a.push(i) ; b.push(i * i) ; i += 1 }
    io.println("two_lists a={a.len()} b={b.len()} a24={a[24]} b24={b[24]}")
}

// Element widths the cache has to address correctly: a wide inline record, a
// float that stores at its own width, a niche Option, and a byte.
fn wide_elements() {
    var ps: List<Point> = []
    var i: int = 0
    for i < 11 { ps.push(Point { x: i, y: i * i }) ; i += 1 }
    var sum: int = 0
    var j: int = 0
    for j < ps.len() { sum += ps[j].y ; j += 1 }
    io.println("wide_elements len={ps.len()} sum={sum} y10={ps[10].y}")
}

fn float_elements() {
    var fs: List<f32> = []
    var i: int = 0
    for i < 13 { fs.push((i as f32) * 0.5) ; i += 1 }
    io.println("float_elements len={fs.len()} at12={fs[12]}")
}

fn option_elements() {
    var os: List<Option<int>> = []
    var i: int = 0
    for i < 15 {
        if i % 2 == 0 { os.push(some(i)) } else { os.push(none) }
        i += 1
    }
    var total: int = 0
    for o: Option<int> in os {
        match o { some(v) => { total += v } none => {} }
    }
    io.println("option_elements len={os.len()} total={total}")
}

fn byte_elements() {
    var bs: List<u8> = []
    var i: int = 0
    for i < 300 { bs.push((i % 251) as u8) ; i += 1 }
    io.println("byte_elements len={bs.len()} at299={bs[299]}")
}

// Elements that own references are out of the cache's scope on purpose: the
// runtime keeps the write barrier, the retain and the per-element release.
// They still have to answer the same as they always did.
fn reference_elements() {
    var cs: List<Counter> = []
    var i: int = 0
    for i < 12 { cs.push(new Counter(i)) ; i += 1 }
    var total: int = 0
    for c: Counter in cs { total += c.n }
    var ss: List<string> = []
    var k: int = 0
    for k < 6 { ss.push("s{k}") ; k += 1 }
    io.println("reference_elements counters={cs.len()} total={total} strings={ss.len()} at5={ss[5]}")
}

// An operation the cache does not serve keeps the whole loop on the runtime.
fn unserved_operations() {
    var xs: List<int> = []
    var i: int = 0
    for i < 14 {
        xs.push(i)
        if i == 6 { xs.insert(0, 99) }
        if i == 9 { xs.sort() }
        i += 1
    }
    io.println("unserved_operations len={xs.len()} at0={xs[0]} at13={xs[13]}")
}

// A list a closure captured is reachable from somewhere the loop cannot see.
fn captured() {
    var xs: List<int> = []
    let add: fn(int) -> unit = fn(v: int) { xs.push(v) }
    var i: int = 0
    for i < 9 { add(i) ; i += 1 }
    io.println("captured len={xs.len()}")
}

// One borrow feeding two served operations: the length the push reads is the
// one the cache is carrying, not the one still in the object.
fn push_own_length() {
    var xs: List<int> = []
    var i: int = 0
    for i < 13 { xs.push(xs.len() + i) ; i += 1 }
    io.println("push_own_length len={xs.len()} at12={xs[12]}")
}

// A prefix sum in place: an index read of the slot the previous turn wrote,
// through the same cached data pointer.
fn prefix_sum() {
    var xs: List<int> = []
    var i: int = 0
    for i < 20 { xs.push(i) ; i += 1 }
    var k: int = 1
    for k < xs.len() { xs[k] = xs[k - 1] + xs[k] ; k += 1 }
    io.println("prefix_sum at19={xs[19]} len={xs.len()}")
}

// The proof travels with a generic template, and the element type decides at
// the instance: `collect<int>` caches, `collect<string>` cannot.
fn collect<T>(source: List<T>, times: int) -> List<T> {
    var out: List<T> = []
    var i: int = 0
    for i < times {
        var j: int = 0
        for j < source.len() { out.push(source[j]) ; j += 1 }
        i += 1
    }
    return move out
}

fn generic_instances() {
    let numbers: List<int> = [4, 5, 6]
    let widened: List<int> = collect(numbers, 7)
    let names: List<string> = ["x", "y"]
    let repeated: List<string> = collect(names, 3)
    io.println("generic_instances ints={widened.len()} at20={widened[20]} strings={repeated.len()} at5={repeated[5]}")
}

fn built() -> List<int> {
    var xs: List<int> = []
    var i: int = 0
    for i < 21 { xs.push(i) ; i += 1 }
    return move xs
}

fn main() {
    push_and_read()
    drain()
    drain_is_empty()
    index_writes()
    interleaved()
    io.println("broke_out {broke_out()}")
    io.println("returned_early {returned_early(8)} {returned_early(400)}")
    nested()
    iterate_after()
    calls_inside()
    two_lists()
    wide_elements()
    float_elements()
    option_elements()
    byte_elements()
    reference_elements()
    unserved_operations()
    captured()
    push_own_length()
    prefix_sum()
    generic_instances()
    let b: List<int> = built()
    io.println("built len={b.len()} at20={b[20]}")
}
