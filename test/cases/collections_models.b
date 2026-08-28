// Each std.collections structure is checked against an independent linear
// model built from plain lists: the structure and the model see the same
// randomized operation stream, and every answer the structure gives is
// compared to the answer the model computes by brute force. A single wrong
// rotation, a lost tie-break or an off-by-one in a range scan turns the error
// count non-zero, which changes the printed line and fails the golden on both
// backends. n is in the thousands on purpose — a rotation case or a two-child
// delete never shows up at n=1.

import std.io
import std.collections
import std.fmt

// ---- shared linear-model helpers -------------------------------------------

fn model_index(keys: List<int>, key: int) -> int {
    var index: int = 0
    for index < keys.len() {
        if keys.get(index).or(0) == key { return index }
        index += 1
    }
    return -1
}

// Insert or replace into a list kept in ascending key order.
fn sorted_set(keys: List<int>, values: List<int>, key: int, value: int) {
    var index: int = 0
    for index < keys.len() {
        let here: int = keys.get(index).or(0)
        if here == key {
            values.remove(index)
            values.insert(index, value)
            return
        }
        if here > key { break }
        index += 1
    }
    keys.insert(index, key)
    values.insert(index, value)
}

fn sorted_remove(keys: List<int>, values: List<int>, key: int) -> bool {
    let at: int = model_index(keys, key)
    if at < 0 { return false }
    keys.remove(at)
    values.remove(at)
    return true
}

// ---- SortedMap =============================================================

fn check_sorted_map() -> int {
    var map: collections.SortedMap<int, int> = new()
    var keys: List<int> = []
    var values: List<int> = []
    var errors: int = 0
    var seed: u64 = 0x9e3779b97f4a7c15
    var step: int = 0
    for step < 6000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let key: int = (seed % 251) as int
        let operation: int = step % 7
        let at: int = model_index(keys, key)
        if operation < 3 {
            let value: int = ((seed >> 19) as int) ^ step
            map.set(key, value)
            sorted_set(keys, values, key, value)
        } else if operation == 3 {
            let value: int = ((seed >> 19) as int) ^ step
            let expected: bool = at < 0
            if map.insert(key, value) != expected { errors += 1 }
            if expected { sorted_set(keys, values, key, value) }
        } else if operation == 4 {
            let expected: bool = at >= 0
            if map.remove(key) != expected { errors += 1 }
            sorted_remove(keys, values, key)
        } else if operation == 5 {
            let want: int = if at < 0 { -1 } else { values.get(at).or(-1) }
            if map.get(key).or(-1) != want { errors += 1 }
            if map.contains_key(key) != (at >= 0) { errors += 1 }
        } else {
            // Ordered queries the hash map cannot answer, each brute-forced.
            var floor: int = -1
            var ceiling: int = -1
            var lower: int = -1
            var higher: int = -1
            var rank: int = 0
            var index: int = 0
            for index < keys.len() {
                let existing: int = keys.get(index).or(0)
                if existing < key { rank += 1 }
                if existing <= key { floor = existing }
                if existing < key { lower = existing }
                if ceiling < 0 && existing >= key { ceiling = existing }
                if higher < 0 && existing > key { higher = existing }
                index += 1
            }
            if map.floor_key(key).or(-1) != floor { errors += 1 }
            if map.ceiling_key(key).or(-1) != ceiling { errors += 1 }
            if map.lower_key(key).or(-1) != lower { errors += 1 }
            if map.higher_key(key).or(-1) != higher { errors += 1 }
            if map.rank(key) != rank { errors += 1 }
        }
        if map.len() != keys.len() { errors += 1 }
        step += 1
    }

    // Whole-structure agreement: keys come back in sorted order, key_at is the
    // model's index, and a pruned range scan matches a brute-force filter.
    let got_keys: List<int> = map.keys()
    if got_keys.len() != keys.len() { errors += 1 }
    var checksum: int = 0
    var index: int = 0
    for index < keys.len() {
        let want: int = keys.get(index).or(-2)
        if got_keys.get(index).or(-1) != want { errors += 1 }
        if map.key_at(index).or(-1) != want { errors += 1 }
        if map.value_at(index).or(-1) != values.get(index).or(-2) { errors += 1 }
        checksum = checksum ^ (want * 65537) ^ values.get(index).or(0)
        index += 1
    }
    if map.first_key().or(-1) != keys.first().or(-1) { errors += 1 }
    if map.last_key().or(-1) != keys.last().or(-1) { errors += 1 }

    // A handful of ranges, each checked against a brute-force filter.
    var lo: int = 0
    for lo < 250 {
        let hi: int = lo + 37
        var expected: List<int> = []
        for k: int in keys {
            if k >= lo && k < hi { expected.push(k) }
        }
        let scanned: List<int> = map.range_keys(lo, hi)
        if scanned.len() != expected.len() { errors += 1 }
        if map.range_count(lo, hi) != expected.len() { errors += 1 }
        var j: int = 0
        for j < expected.len() {
            if scanned.get(j).or(-1) != expected.get(j).or(-2) { errors += 1 }
            j += 1
        }
        lo += 41
    }

    io.println("sortedmap model {errors} {map.len()} {checksum}")
    return errors
}

// ---- Set ===================================================================

// Order-independent so Set iteration order (the map's, unspecified) never
// decides the answer.
fn set_checksum(values: List<int>) -> int {
    var sum: int = 0
    for value: int in values { sum = sum ^ (value * 2654435761) }
    return sum
}

fn in_range(value: int, lo: int, hi: int) -> bool {
    return value >= lo && value < hi
}

fn range_set(lo: int, hi: int) -> collections.Set<int> {
    var s: collections.Set<int> = new()
    var i: int = lo
    for i < hi {
        s.add(i)
        i += 1
    }
    return s
}

// An algebra result is right when it has the model's length and the same
// order-independent checksum; either miss is one error.
fn set_match(got: List<int>, want: List<int>) -> int {
    if got.len() != want.len() { return 1 }
    if set_checksum(got) != set_checksum(want) { return 1 }
    return 0
}

// Every set-algebra method on two contiguous ranges A=[a_lo,a_hi) and
// B=[b_lo,b_hi), in both argument orders, against models built by range
// arithmetic. Different-sized ranges make one call take both the walk-smaller
// and the clone-larger branch: within a.union_with(b) and b.union_with(a) the
// larger side is once the receiver and once the argument, and likewise for the
// smaller side that intersection and is_disjoint_from walk. So a walk of the
// wrong side, a dropped early exit or a union that forgets to merge the
// smaller side turns the error count non-zero and fails the golden.
fn check_ranges(a_lo: int, a_hi: int, b_lo: int, b_hi: int) -> int {
    var errors: int = 0
    let a: collections.Set<int> = range_set(a_lo, a_hi)
    let b: collections.Set<int> = range_set(b_lo, b_hi)

    var union_model: List<int> = []
    var inter_model: List<int> = []
    var diff_ab_model: List<int> = []
    var diff_ba_model: List<int> = []
    var sym_model: List<int> = []
    var v: int = a_lo
    for v < a_hi {
        union_model.push(v)
        if in_range(v, b_lo, b_hi) {
            inter_model.push(v)
        } else {
            diff_ab_model.push(v)
            sym_model.push(v)
        }
        v += 1
    }
    v = b_lo
    for v < b_hi {
        if !in_range(v, a_lo, a_hi) {
            union_model.push(v)
            diff_ba_model.push(v)
            sym_model.push(v)
        }
        v += 1
    }

    let uab: collections.Set<int> = a.union_with(b)
    let uba: collections.Set<int> = b.union_with(a)
    errors += set_match(uab.items(), union_model)
    errors += set_match(uba.items(), union_model)

    let iab: collections.Set<int> = a.intersection(b)
    let iba: collections.Set<int> = b.intersection(a)
    errors += set_match(iab.items(), inter_model)
    errors += set_match(iba.items(), inter_model)

    let dab: collections.Set<int> = a.difference(b)
    let dba: collections.Set<int> = b.difference(a)
    errors += set_match(dab.items(), diff_ab_model)
    errors += set_match(dba.items(), diff_ba_model)

    let sab: collections.Set<int> = a.symmetric_difference(b)
    let sba: collections.Set<int> = b.symmetric_difference(a)
    errors += set_match(sab.items(), sym_model)
    errors += set_match(sba.items(), sym_model)

    // Predicate truth read off the models: A ⊆ B iff A\B is empty, the two
    // sets are disjoint iff they intersect in nothing, and equal iff each is a
    // subset of the other.
    let sub_ab: bool = diff_ab_model.len() == 0
    let sub_ba: bool = diff_ba_model.len() == 0
    let disjoint: bool = inter_model.len() == 0
    let equal: bool = sub_ab && sub_ba
    if a.is_subset_of(b) != sub_ab { errors += 1 }
    if b.is_subset_of(a) != sub_ba { errors += 1 }
    if a.is_superset_of(b) != sub_ba { errors += 1 }
    if b.is_superset_of(a) != sub_ab { errors += 1 }
    if a.is_disjoint_from(b) != disjoint { errors += 1 }
    if b.is_disjoint_from(a) != disjoint { errors += 1 }
    if a.equals(b) != equal { errors += 1 }
    if b.equals(a) != equal { errors += 1 }
    return errors
}

// A set against itself: the union and the intersection are the set, the two
// differences are empty, it equals and contains itself, and it is disjoint
// from itself only when it is empty. The clone-then-walk union must not be
// confused by the source and the copy sharing members.
fn check_self(lo: int, hi: int) -> int {
    var errors: int = 0
    let a: collections.Set<int> = range_set(lo, hi)
    var members: List<int> = []
    var v: int = lo
    for v < hi {
        members.push(v)
        v += 1
    }
    let empty: List<int> = []
    errors += set_match(a.union_with(a).items(), members)
    errors += set_match(a.intersection(a).items(), members)
    errors += set_match(a.difference(a).items(), empty)
    errors += set_match(a.symmetric_difference(a).items(), empty)
    if a.equals(a) != true { errors += 1 }
    if a.is_subset_of(a) != true { errors += 1 }
    if a.is_superset_of(a) != true { errors += 1 }
    if a.is_disjoint_from(a) != (hi <= lo) { errors += 1 }
    return errors
}

// The algebra at n in the thousands, across the shapes the churn above never
// reaches: partial overlap with each side larger in turn, fully disjoint,
// identical, a proper subset, an empty operand on either side, both empty, and
// a set against itself.
fn check_set_algebra() -> int {
    var errors: int = 0
    // Partial overlap at n in the thousands with the sides different sizes, so
    // this one call takes both the walk-smaller and the clone-larger branch.
    errors += check_ranges(0, 2000, 1200, 3000)
    // Disjoint, identical, and a proper subset — each a shape the churn above
    // never lands on — with the sides different sizes where that is possible.
    errors += check_ranges(0, 1000, 3000, 3800)
    errors += check_ranges(0, 1000, 0, 1000)
    errors += check_ranges(0, 1200, 300, 800)
    // An empty operand on either side, and both empty.
    errors += check_ranges(0, 1000, 0, 0)
    errors += check_ranges(0, 0, 0, 1000)
    errors += check_ranges(0, 0, 0, 0)
    // A set against itself, at scale and empty.
    errors += check_self(0, 1200)
    errors += check_self(0, 0)
    return errors
}

fn check_set() -> int {
    var set: collections.Set<int> = new()
    var members: List<int> = []
    var errors: int = 0
    var seed: u64 = 0xd1b54a32d192ed03
    var step: int = 0
    for step < 4000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let value: int = (seed % 149) as int
        let at: int = model_index(members, value)
        let operation: int = step % 4
        if operation < 2 {
            let expected: bool = at < 0
            if set.add(value) != expected { errors += 1 }
            if expected { members.push(value) }
        } else if operation == 2 {
            let expected: bool = at >= 0
            if set.remove(value) != expected { errors += 1 }
            if expected { members.remove(at) }
        } else {
            if set.contains(value) != (at >= 0) { errors += 1 }
        }
        if set.len() != members.len() { errors += 1 }
        step += 1
    }
    if set_checksum(set.items()) != set_checksum(members) { errors += 1 }

    // Algebra against a second set, each result brute-forced from the models.
    var other: collections.Set<int> = new()
    var others: List<int> = []
    var index: int = 0
    for index < members.len() {
        if index % 2 == 0 {
            let value: int = members.get(index).or(0)
            other.add(value)
            others.push(value)
        }
        index += 1
    }
    other.add(1000)
    others.push(1000)

    var union_model: List<int> = []
    for value: int in members { union_model.push(value) }
    for value: int in others {
        if model_index(members, value) < 0 { union_model.push(value) }
    }
    if set.union_with(other).len() != union_model.len() { errors += 1 }
    if set_checksum(set.union_with(other).items()) !=
       set_checksum(union_model) { errors += 1 }

    var inter_model: List<int> = []
    for value: int in members {
        if model_index(others, value) >= 0 { inter_model.push(value) }
    }
    if set_checksum(set.intersection(other).items()) !=
       set_checksum(inter_model) { errors += 1 }

    var diff_model: List<int> = []
    for value: int in members {
        if model_index(others, value) < 0 { diff_model.push(value) }
    }
    if set_checksum(set.difference(other).items()) !=
       set_checksum(diff_model) { errors += 1 }

    var sym_model: List<int> = []
    for value: int in diff_model { sym_model.push(value) }
    for value: int in others {
        if model_index(members, value) < 0 { sym_model.push(value) }
    }
    if set_checksum(set.symmetric_difference(other).items()) !=
       set_checksum(sym_model) { errors += 1 }

    // The even-indexed members form a subset; add 1000 (never a member) and it
    // stops being one.
    var even: collections.Set<int> = new()
    var evens: List<int> = []
    var pick: int = 0
    for pick < members.len() {
        if pick % 2 == 0 {
            even.add(members.get(pick).or(0))
            evens.push(members.get(pick).or(0))
        }
        pick += 1
    }
    if evens.len() != 0 {
        if even.is_subset_of(set) != true { errors += 1 }
        if set.is_superset_of(even) != true { errors += 1 }
    }
    if other.is_subset_of(set) != false { errors += 1 }
    // An intersection and a difference share nothing by construction.
    if set.intersection(other).is_disjoint_from(set.difference(other)) != true {
        errors += 1
    }
    if set.equals(set) != true { errors += 1 }

    // The algebra again, at scale and across the empty/identical/disjoint/self
    // shapes. This touches neither `set` nor `members`, so a correct run leaves
    // the printed line — errors, length and checksum — exactly as the golden
    // pins it.
    errors += check_set_algebra()

    io.println("set model {errors} {set.len()} {set_checksum(members)}")
    return errors
}

// ---- Deque =================================================================

fn check_deque() -> int {
    var deque: collections.Deque<int> = new()
    // model index 0 is the head, matching Deque.get(0).
    var model: List<int> = []
    var errors: int = 0
    var seed: u64 = 0x2545f4914f6cdd1d
    var step: int = 0
    for step < 6000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let value: int = (seed >> 13) as int
        let operation: int = (seed % 5) as int
        if operation == 0 {
            deque.push_front(value)
            model.insert(0, value)
        } else if operation == 1 {
            deque.push_back(value)
            model.push(value)
        } else if operation == 2 {
            let want: int = if model.len() == 0 { -777 } else { model.get(0).or(0) }
            let got: int = deque.pop_front().or(-777)
            if got != want { errors += 1 }
            if model.len() != 0 { model.remove(0) }
        } else if operation == 3 {
            let last: int = model.len() - 1
            let want: int = if last < 0 { -777 } else { model.get(last).or(0) }
            let got: int = deque.pop_back().or(-777)
            if got != want { errors += 1 }
            if last >= 0 { model.remove(last) }
        } else {
            if deque.len() != model.len() { errors += 1 }
            if model.len() != 0 {
                let last: int = model.len() - 1
                if deque.first().or(-777) != model.get(0).or(0) { errors += 1 }
                if deque.last().or(-777) != model.get(last).or(0) { errors += 1 }
                let probe: int = (seed >> 40) as int % model.len()
                let idx: int = if probe < 0 { -probe } else { probe }
                if deque.get(idx).or(-777) != model.get(idx).or(0) { errors += 1 }
            }
        }
        if deque.len() != model.len() { errors += 1 }
        step += 1
    }
    // Drain both ends until empty, comparing every element in order.
    var checksum: int = 0
    for model.len() != 0 {
        let head: int = deque.pop_front().or(-777)
        if head != model.get(0).or(0) { errors += 1 }
        model.remove(0)
        checksum = checksum * 31 + head
    }
    if deque.pop_front().is_some() { errors += 1 }
    if deque.pop_back().is_some() { errors += 1 }
    io.println("deque model {errors} {checksum}")
    return errors
}

// The random walk in check_deque stays a few hundred elements deep, so with a
// 512-slot block it never leaves the head block — no crossover, no inner-block
// get. This case drives the deque past several full blocks on BOTH sides so the
// block map, both crossovers (multi-block and the lone-block split), the spare
// and every region of get() are exercised. It is checked against the same
// linear list model and folds every drained value into a checksum, so a wrong
// crossover, a lost reverse or an off-by-one in the get formula moves the
// printed line and fails the golden on both backends.
fn check_deque_blocks() -> int {
    var deque: collections.Deque<int> = new()
    var model: List<int> = []   // index 0 is the head
    var errors: int = 0
    var checksum: int = 0
    var seed: u64 = 0x9e3779b97f4a7c15

    // Grow past 2*BLOCK on the back, then past 2*BLOCK on the front, so each
    // side spans several full blocks with a partial block outermost.
    var i: int = 0
    for i < 1600 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let value: int = (seed >> 11) as int
        deque.push_back(value)
        model.push(value)
        i += 1
    }
    i = 0
    for i < 1600 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let value: int = (seed >> 11) as int
        deque.push_front(value)
        model.insert(0, value)
        i += 1
    }
    if deque.len() != model.len() { errors += 1 }
    // get in every region: head partial block, inner front blocks, inner back
    // blocks, tail partial block — a coprime stride visits them all.
    var probe: int = 0
    for probe < model.len() {
        if deque.get(probe).or(-777) != model.get(probe).or(0) { errors += 1 }
        probe += 137
    }
    if deque.first().or(-777) != model.get(0).or(0) { errors += 1 }
    if deque.last().or(-777) != model.get(model.len() - 1).or(0) { errors += 1 }
    if deque.get(-1).is_some() { errors += 1 }
    if deque.get(model.len()).is_some() { errors += 1 }

    // Drain across the middle from both ends alternately: each side empties in
    // turn, so both crossovers fire repeatedly against the other side's blocks.
    var toggle: int = 0
    for model.len() != 0 {
        if toggle % 2 == 0 {
            let want: int = model.get(0).or(0)
            let got: int = deque.pop_front().or(-777)
            if got != want { errors += 1 }
            checksum = checksum * 31 + got
            model.remove(0)
        } else {
            let last: int = model.len() - 1
            let want: int = model.get(last).or(0)
            let got: int = deque.pop_back().or(-777)
            if got != want { errors += 1 }
            checksum = checksum * 31 + got
            model.remove(last)
        }
        toggle += 1
    }
    if deque.len() != 0 { errors += 1 }

    // Pure FIFO across many blocks (push_back N, pop_front N): the multi-block
    // crossover that moves the head half of a full back side to the front, over
    // and over. Values are deterministic, so each pop is checked, not only
    // folded into the checksum — a lost block reverse must raise errors here,
    // not merely change the golden.
    i = 0
    for i < 4000 { deque.push_back(i * 3 + 1); i += 1 }
    i = 0
    for i < 4000 {
        let got: int = deque.pop_front().or(-777)
        if got != i * 3 + 1 { errors += 1 }
        checksum = checksum * 31 + got
        i += 1
    }
    // The mirror: push_front N, pop_back N drains from the tail in push order,
    // exercising multi-block crossover_to_back.
    i = 0
    for i < 4000 { deque.push_front(i * 5 + 2); i += 1 }
    i = 0
    for i < 4000 {
        let got: int = deque.pop_back().or(-777)
        if got != i * 5 + 2 { errors += 1 }
        checksum = checksum * 31 + got
        i += 1
    }
    if deque.len() != 0 { errors += 1 }

    // Single-partial-block ping-pong (size never exceeds 1) then a boundary
    // thrash at exactly 2*BLOCK: neither may churn or lose an element.
    i = 0
    for i < 2000 {
        deque.push_back(i)
        if deque.pop_front().or(-1) != i { errors += 1 }
        i += 1
    }
    var m4: List<int> = []
    i = 0
    for i < 1024 { deque.push_back(i); m4.push(i); i += 1 }
    i = 0
    for i < 3000 {
        deque.push_back(200000 + i)
        m4.push(200000 + i)
        let last: int = m4.len() - 1
        let got: int = deque.pop_back().or(-1)
        if got != m4.get(last).or(-2) { errors += 1 }
        checksum = checksum * 31 + got
        m4.remove(last)
        i += 1
    }
    for m4.len() != 0 {
        let last: int = m4.len() - 1
        if deque.pop_back().or(-1) != m4.get(last).or(-2) { errors += 1 }
        m4.remove(last)
    }
    if deque.len() != 0 { errors += 1 }

    io.println("deque blocks {errors} {checksum}")
    return errors
}

// ---- PriorityQueue =========================================================

fn check_priority_queue() -> int {
    var queue: collections.PriorityQueue<int, int> = new()
    // Parallel model: priority, push order, payload.
    var pri: List<int> = []
    var seq: List<int> = []
    var val: List<int> = []
    var errors: int = 0
    var seed: u64 = 0x94d049bb133111eb
    var pushed: int = 0
    var step: int = 0
    for step < 6000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let operation: int = (seed % 3) as int
        if operation != 0 || queue.len() == 0 {
            let priority: int = (seed % 29) as int
            queue.push(priority, pushed)
            pri.push(priority)
            seq.push(pushed)
            val.push(pushed)
            pushed += 1
        } else {
            // The model's next-out: smallest priority, then earliest push.
            var best: int = 0
            var index: int = 1
            for index < pri.len() {
                let bp: int = pri.get(best).or(0)
                let ip: int = pri.get(index).or(0)
                if ip < bp || (ip == bp && seq.get(index).or(0) < seq.get(best).or(0)) {
                    best = index
                }
                index += 1
            }
            let want_priority: int = pri.get(best).or(-1)
            if queue.peek_priority().or(-1) != want_priority { errors += 1 }
            if queue.pop().or(-1) != val.get(best).or(-1) { errors += 1 }
            pri.remove(best)
            seq.remove(best)
            val.remove(best)
        }
        if queue.len() != pri.len() { errors += 1 }
        step += 1
    }
    // Drain in full and confirm priorities come out non-decreasing.
    var previous: int = -1
    var drained: int = 0
    for queue.len() != 0 {
        let priority: int = queue.peek_priority().or(-1)
        if priority < previous { errors += 1 }
        previous = priority
        queue.pop()
        drained += 1
    }
    if drained != pri.len() { errors += 1 }
    io.println("pqueue model {errors} {pushed}")
    return errors
}

// ---- StringBuilder =========================================================

fn check_builder() -> int {
    var errors: int = 0
    var builder: fmt.StringBuilder = new fmt.StringBuilder()
    var reference: List<string> = []
    var index: int = 0
    for index < 2000 {
        if index % 3 == 0 {
            builder.push_int(index)
            reference.push("{index}")
        } else if index % 3 == 1 {
            builder.push("piece")
            reference.push("piece")
        } else {
            builder.push_bool(index % 2 == 0)
            reference.push(if index % 2 == 0 { "true" } else { "false" })
        }
        index += 1
    }
    let built: string = builder.to_string()
    let joined: string = reference.join("")
    if built != joined { errors += 1 }
    if builder.len() != joined.len() { errors += 1 }
    builder.clear()
    if !builder.is_empty() { errors += 1 }
    io.println("builder {errors} {built.len()}")
    return errors
}

fn main() {
    var errors: int = 0
    errors += check_sorted_map()
    errors += check_set()
    errors += check_deque()
    errors += check_deque_blocks()
    errors += check_priority_queue()
    errors += check_builder()
    io.println("total errors {errors}")
}
