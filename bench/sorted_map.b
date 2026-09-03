// SortedMap<int, int> against std::map: the ordered map under the loads that
// make people reach for one. Two fills — ascending keys, which is the shape a
// time-series index actually sees and the case a balanced tree exists for, and
// scattered keys, which is the ordinary one — then point lookups half of which
// miss, `ceiling_key` on keys that are not members, an ordered scan of every
// key, a removal of half the entries, and an ordered scan of what survived.
//
// The C++ twin is std::map, a red-black tree: a different balance scheme over
// the same ordered-map contract, so the row compares two balanced trees doing
// the same work. `rank`, `key_at` and `range_count` are left out on purpose —
// SortedMap keeps subtree sizes and answers them in O(log n) while std::map
// has to walk, and a row where the two sides run different algorithms measures
// the algorithms, not the implementations.
//
// The checksum is a position-weighted product folded into a wrapping sum, the
// same one bench/deque.b uses: one add on the dependency chain, and the
// multiply and the weight step off it. Every phase folds what it observed, so
// a wrong value, a wrong count or a scan in the wrong order all move it.
import std.io
import std.os
import std.collections

// A bijection on [0, 2^40): multiply by an odd constant modulo 2^40, then an
// xor-shift finalizer. Ascending indices come out scattered, and because it is
// a bijection the scattered map holds exactly as many keys as the ascending
// one — the two fills differ in insertion order and nothing else.
fn scatter(index: int) -> int {
    let mixed: int = (index * 2654435761) & 1099511627775
    return mixed ^ (mixed >> 20)
}

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(400_000)
    let seed: int = args.get(1).or("").to_int().or(1)
    var checksum: int = 0
    var weight: int = 1

    // 1. Ascending fill. Every key is larger than every key already there, so
    //    each insert descends the right spine and the rebalance runs on the
    //    way back out — the AVL's worst case and a time series' normal one.
    var series: collections.SortedMap<int, int> = new()
    var i: int = 0
    for i < n {
        series.set(i, i + seed)
        i += 1
    }
    checksum = checksum + series.len() * weight
    weight += 2654435761

    // 2. Scattered fill: the same number of keys arriving in no order.
    var index: collections.SortedMap<int, int> = new()
    i = 0
    for i < n {
        index.set(scatter(i), i + seed)
        i += 1
    }
    checksum = checksum + index.len() * weight
    weight += 2654435761

    // 3. Point lookups. `scatter(i * 2)` is a member exactly while i * 2 < n,
    //    so half of these hit and half walk to a leaf and answer none.
    i = 0
    for i < n {
        checksum = checksum + index.get(scatter(i * 2)).or(0) * weight
        weight += 2654435761
        i += 1
    }

    // 4. Neighbour queries. No `scatter(i) + 1` is a member, so every descent
    //    has to carry a candidate down and answer with it — except the single
    //    probe above the largest key, which answers none and folds -1.
    i = 0
    for i < n {
        checksum = checksum + index.ceiling_key(scatter(i) + 1).or(-1) * weight
        weight += 2654435761
        i += 1
    }

    // 5. Ordered scan: every key of the ascending map, in order, into a list.
    let keys: List<int> = series.keys()
    i = 0
    for i < keys.len() {
        checksum = checksum + keys[i] * weight
        weight += 2654435761
        i += 1
    }

    // 6. Remove half the scattered map, which is where the tree has to splice
    //    a successor in and rebalance on the way back out.
    var removed: int = 0
    i = 0
    for i < n / 2 {
        if index.remove(scatter(i * 2)) { removed += 1 }
        i += 1
    }
    checksum = checksum + removed * weight
    weight += 2654435761

    // 7. Scan what survived. Counting the removals is not enough on its own —
    //    unlinking the wrong key leaves `removed` and `len` exactly right and
    //    the contents wrong — so the surviving keys go into the answer too.
    let left: List<int> = index.keys()
    i = 0
    for i < left.len() {
        checksum = checksum + left[i] * weight
        weight += 2654435761
        i += 1
    }
    checksum = checksum + index.len() * weight

    io.println("sorted_map {checksum} {series.len()} {index.len()}")
}
