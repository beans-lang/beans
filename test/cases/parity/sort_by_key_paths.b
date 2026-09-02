// `sort_by_key` on slot-sized elements has two implementations underneath:
// a stable bottom-up merge below the radix crossover and a stable LSD radix
// above it (beans_list_sort_by_key in runtime/beans_rt.c). A radix pass costs
// 65536 bucket clears and a 65536-wide prefix sum whatever n is, so the merge
// is what keeps a ten-element keyed sort from being a quarter of a million
// fixed operations -- but only if the two agree exactly.
//
// Both are stable, and a stable sort by the same integer keys is one
// permutation, so they must not merely agree on the order: they must agree on
// where equal-keyed elements landed. Every case here has duplicate keys and
// carries the element's original position, and the checksum is
// position-weighted so a swap of two equal-keyed elements changes it.
//
// The crossover scales with the radix pass count, because a pass is what costs
// the fixed 65536: the merge runs below `passes * 4096`. So the sizes have to
// straddle it for each spread -- 4095/4096/4097 for a one-pass span, 9000 for
// two, 17000 for four -- or the widest keys would only ever take the merge and
// their radix would go untested.
import std.io

struct Row {
    key: int
    tag: int
}

fn spread(i: int, mode: int) -> int {
    if mode == 0 { return i % 7 }
    if mode == 1 { return (i * 2654435761) % 65536 }
    if mode == 2 { return (i * 2654435761) % 4000000000 }
    if mode == 3 { return i * 6364136223846793005 }
    return 0 - (i % 11)
}

fn seal(n: int, mode: int) -> int {
    var xs: List<int> = []
    var i: int = 0
    for i < n {
        xs.push(i)
        i += 1
    }
    xs.sort_by_key(fn(v: int) -> int { return spread(v, mode) })
    var out: int = 0
    var seat: int = 0
    for v: int in xs {
        out = (out * 1000003 + v * (seat + 1)) % 1000000007
        seat += 1
    }
    return out
}

// The inline-struct entry point (beans_list_val_sort_by_key) is always the
// merge, and it sorts the same keys: it is the third party that says which of
// the two slot paths is right when they ever disagree.
fn seal_struct(n: int, mode: int) -> int {
    var xs: List<Row> = []
    var i: int = 0
    for i < n {
        xs.push(Row { key: spread(i, mode), tag: i })
        i += 1
    }
    xs.sort_by_key(fn(r: Row) -> int { return r.key })
    var out: int = 0
    var seat: int = 0
    for r: Row in xs {
        out = (out * 1000003 + r.tag * (seat + 1)) % 1000000007
        seat += 1
    }
    return out
}

fn main() {
    for n: int in [0, 1, 2, 3, 7, 8, 9, 63, 64, 65, 1000, 4095, 4096, 4097, 9000, 17000] {
        for mode: int in [0, 1, 2, 3, 4] {
            let slots: int = seal(n, mode)
            let rows: int = seal_struct(n, mode)
            if slots != rows {
                io.println("n {n} mode {mode}: slot path {slots} != merge {rows}")
            } else {
                io.println("n {n} mode {mode}: {slots}")
            }
        }
    }
}
