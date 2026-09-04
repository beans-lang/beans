// What a std.collections container does *while* it is dropping what it owns.
//
// Every case here reaches a container in the middle of an operation, through
// the one door the language leaves open: an element's own `deinit`, which runs
// as the container releases it. The container is a live object at that moment
// and a user's code can read it, mutate it, or panic out of it. None of that
// was covered when these types shipped, and two defects lived in the gap:
//
//   * `Deque.clear()` released its storage before zeroing its counters, so a
//     `deinit` saw the old length over storage that was already gone, and a
//     panic there left the deque permanently torn.
//   * `SortedMap.remove` reported its answer by comparing `len()` before and
//     after the recursion, so a reentrant mutation from a value's `deinit`
//     made it answer `false` for a key it had just removed.
//   * every `Deque` rebalance allocated between its first storage write and
//     its last counter write, so a `deinit` the cycle collector ran at one of
//     those allocations read a length that did not match the storage, or the
//     contents backwards, or indexed past a block that had just been drained.
//   * `PriorityQueue.push` and `.pop` sift the heap through a hole, so between
//     the first entry write and the last the root slot held a stale entry while
//     `entries.len()` had already changed; `len()` and `peek()` disagreed. #92.
//   * `SortedMap` linked an inserted node deep in the tree and refreshed the
//     root's cached `size` only on the way back up, so `len()` disagreed with
//     the keys `contains_key` could already find; a remove tore the other way.
//     #92.
//
// The rule they all break is the one the runtime containers already follow:
// a container is settled before it drops anything, and it stays usable after a
// contained panic. A change of shape is published with a single store — the
// deque swaps its shape object, the queue its view, the map its root — so a
// reader between two writes sees the whole old shape or the whole new one,
// never a torn one. `List` and `Map` are printed alongside as the reference.
//
// n is past 512 wherever a Deque is involved, so more than one block dies.

import std.io
import std.collections

// ---- part 1: a deinit that reads the container it is being dropped from ----

class DequeWatcher {
    id: int = 0
    owner: Option<collections.Deque<DequeWatcher>> = none
    pub fn init(id: int) { self.id = id }
    fn deinit() {
        match self.owner {
            some(d) => {
                if d.len() != 0 || !d.is_empty() {
                    Seen.torn_deque += 1
                }
                match d.first() { some(v) => { Seen.torn_deque += 1 } none => {} }
            }
            none => {}
        }
    }
}

class Seen {
    pub static torn_deque: int = 0
    pub static answers: int = 0
    pub static crossover_probes: int = 0
    pub static pq_probes: int = 0
    pub static torn_pq: int = 0
    pub static sm_probes: int = 0
    pub static torn_sm: int = 0
    // Roots that keep the probed queue and map alive for the whole run. The
    // probes below hold their container from inside a two-node cycle, and if
    // that cycle were the container's only reference the collector would sweep
    // the container together with the probes and a `deinit` would read a freed
    // container rather than a torn one. A root keeps the container live, so
    // every probe reads exactly what the container holds at that moment.
    pub static held_pq: Option<collections.PriorityQueue<int, int>> = none
    pub static held_sm: Option<collections.SortedMap<int, int>> = none
}

fn clear_watching_deque() {
    var d: collections.Deque<DequeWatcher> = new()
    var i: int = 0
    for i < 600 {
        var w: DequeWatcher = new DequeWatcher(i)
        w.owner = some(d)
        d.push_back(w)
        i += 1
    }
    d.clear()
}

// ---- part 2: a deinit that panics while the container is clearing ----

class Bomb {
    id: int = 0
    pub fn init(id: int) { self.id = id }
    fn deinit() { if self.id == 1 { panic("deinit raised during clear") } }
}

fn wipe_deque(d: collections.Deque<Bomb>) -> int { d.clear(); return 0 }
fn wipe_list(l: List<Bomb>) -> int { l.clear(); return 0 }

fn panic_during_clear() {
    var d: collections.Deque<Bomb> = new()
    var l: List<Bomb> = []
    var i: int = 0
    for i < 3 {
        d.push_back(new Bomb(i))
        l.push(new Bomb(i))
        i += 1
    }
    let hd: Brew<int> = brew wipe_deque(d)
    match hd.join() { ok(v) => {} err(e) => {} }
    // The container must be usable — and empty — the moment the panic is
    // contained. A torn deque answers its old length over empty storage, and
    // the next read panics from inside the stdlib.
    io.println("deque after contained panic: len {d.len()} empty {d.is_empty()} first {d.first().is_some()}")
    let hl: Brew<int> = brew wipe_list(l)
    match hl.join() { ok(v) => {} err(e) => {} }
    io.println("list  after contained panic: len {l.len()}")
}

// ---- part 3: a value's deinit mutating the SortedMap that owned it ----

class Reentrant {
    id: int = 0
    map: Option<collections.SortedMap<int, Reentrant>> = none
    pub fn init(id: int) { self.id = id }
    fn deinit() {
        match self.map {
            some(m) => {
                // Mutating here changes the map's size while `remove` is
                // still unwinding its own recursion. An answer inferred from
                // a size difference is wrong from this point on.
                if self.id == 5 { m.set(9000 + self.id, new Reentrant(-1)) }
            }
            none => {}
        }
    }
}

fn reentrant_remove() {
    var m: collections.SortedMap<int, Reentrant> = new()
    var i: int = 0
    for i < 12 {
        var r: Reentrant = new Reentrant(i)
        r.map = some(m)
        m.set(i, r)
        i += 1
    }
    let removed: bool = m.remove(5)
    let gone: bool = !m.contains_key(5)
    // `remove` said what it did, and what it said is what happened.
    if removed == gone { Seen.answers += 1 }
    io.println("sortedmap remove under reentrancy: answered {removed}, key gone {gone}")

    // A key that was never there still answers false, reentrancy or not.
    let absent: bool = m.remove(4242)
    io.println("sortedmap remove of an absent key: {absent}")

    // insert reports the same way: true only when it added.
    var plain: collections.SortedMap<int, int> = new()
    let first: bool = plain.insert(1, 10)
    let again: bool = plain.insert(1, 99)
    io.println("sortedmap insert new {first} duplicate {again} value {plain.get(1)}")
}

// ---- part 4: the crossover, observed from a deinit the collector runs -----

// The crossover moves half of one end across to the other, and it changes
// `front`, `back`, `front_count` and `back_count` to do it. No two of those can
// be written at once, so between the first write and the last the deque
// describes a shape it does not have. That window used to allocate -- a fresh
// block, its `reserve(512)`, the `push` that grew an empty handle list, and the
// `Option` every `pop()` builds -- and an allocation is where the cycle
// collector runs, so a `deinit` landed inside it and read the lie. #86.
//
// This probe holds the deque from inside a two-node cycle, which only the
// collector can free, so the deinit fires at whatever allocation crosses the
// collector's threshold rather than at a point the program chose.
class CrossProbe {
    peer: Option<CrossProbe> = none
    owner: Option<collections.Deque<int>> = none
    pub fn init() {}
    fn deinit() {
        match self.owner {
            some(d) => {
                Seen.crossover_probes += 1
                let n: int = d.len()
                if n > 0 {
                    // The driver keeps one ascending run in the deque at all
                    // times, so this holds exactly when the deque is telling
                    // the truth. It compares the deque against itself and not
                    // against a snapshot, so no legal change can make it lie --
                    // the mistake that made the first probe for this report
                    // read clean.
                    let lo: int = d.get(0).or(0)
                    let hi: int = d.get(n - 1).or(0)
                    if hi - lo != n - 1 { Seen.torn_deque += 1 }
                    if d.first().or(0) != lo { Seen.torn_deque += 1 }
                    if d.last().or(0) != hi { Seen.torn_deque += 1 }
                }
            }
            none => {}
        }
    }
}

fn watch(d: collections.Deque<int>) {
    var a: CrossProbe = new CrossProbe()
    var b: CrossProbe = new CrossProbe()
    a.owner = some(d)
    b.owner = some(d)
    a.peer = some(b)
    b.peer = some(a)
    // a and b are garbage now, and only the collector can prove it.
}

// Every pop here comes off the empty end, so each one rebalances. The size
// walks, and that matters: with rounds that repeat exactly, the collector's
// threshold lands on the same allocation every time and the probe samples one
// point of the window forever -- 800k collector-driven reads of a torn deque
// saw nothing that way. A size that never repeats moves the landing point
// around the window instead.
fn crossover_under_release() {
    var d: collections.Deque<int> = new()
    var round: int = 0
    var fill: int = 1
    for round < 26 {
        fill = fill + 1
        if fill > 300 { fill = 1 }

        // one block, drained from the empty end: crossover_to_front splits it
        var n: int = 0
        var i: int = 0
        for i < fill { d.push_back(n); n += 1; i += 1 }
        var seen: int = 0
        for seen < fill {
            watch(d)
            match d.pop_front() { some(v) => {} none => {} }
            seen += 1
        }

        // the mirror: filled at the head, drained from the tail
        var m: int = fill - 1
        for m >= 0 { d.push_front(m); m -= 1 }
        seen = 0
        for seen < fill {
            watch(d)
            match d.pop_back() { some(v) => {} none => {} }
            seen += 1
        }

        // past 512, so blocks move as handles and the multi-block branch runs
        let wide: int = 1100 + fill * 6
        n = 0
        i = 0
        for i < wide { d.push_back(n); n += 1; i += 1 }
        seen = 0
        for seen < wide {
            watch(d)
            match d.pop_front() { some(v) => {} none => {} }
            seen += 1
        }
        m = wide - 1
        for m >= 0 { d.push_front(m); m -= 1 }
        seen = 0
        for seen < wide {
            watch(d)
            match d.pop_back() { some(v) => {} none => {} }
            seen += 1
        }
        round += 1
    }
    io.println("crossover churn done: len {d.len()}")
    // A probe that never runs proves nothing, so say so rather than reporting
    // a silent zero.
    io.println("crossover observed under collection: {Seen.crossover_probes > 1000}")
}

// ---- part 5: PriorityQueue push and pop, observed from a collector deinit ---

// A `push` or a `pop` sifts the heap through a hole, so between its first write
// and its last the root slot holds a stale entry while `entries.len()` has
// already changed. `len()` and `peek()` reading the heap directly would see a
// count and a smallest that disagree — that was #92. The fix answers reads from
// a view the operation republishes with one store, so this probe must never see
// them disagree.
//
// The queue holds a contiguous run {base .. N-1}: it is refilled by pushing
// N-1 down to 0 (a partial refill holds {N-j .. N-1}) and drained by popping
// the min (a partial drain holds {k .. N-1}). At every settled point the
// smallest is `base` and the count is `N - base`, so peek_priority() + len()
// is exactly N — a self-relating invariant with a FIXED N, true no matter which
// round's data the queue currently holds, so a probe that outlives its round
// still checks the truth. The payload is priority * 2, checked too, so a torn
// read where `peek` and `peek_priority` fall on different entries is caught.
class PqProbe {
    peer: Option<PqProbe> = none
    owner: Option<collections.PriorityQueue<int, int>> = none
    pub fn init() {}
    fn deinit() {
        match self.owner {
            some(q) => {
                Seen.pq_probes += 1
                let n: int = q.len()
                if n > 0 {
                    match q.peek_priority() {
                        some(p) => {
                            if p + n != 200 { Seen.torn_pq += 1 }
                            match q.peek() {
                                some(v) => { if v != p * 2 { Seen.torn_pq += 1 } }
                                none => { Seen.torn_pq += 1 }
                            }
                        }
                        none => { Seen.torn_pq += 1 }
                    }
                }
            }
            none => {}
        }
    }
}

fn pq_watch(q: collections.PriorityQueue<int, int>) {
    var a: PqProbe = new PqProbe()
    var b: PqProbe = new PqProbe()
    a.owner = some(q)
    b.owner = some(q)
    a.peer = some(b)
    b.peer = some(a)
    // a and b are garbage now, and only the collector can prove it.
}

fn pq_under_release() {
    var q: collections.PriorityQueue<int, int> = new()
    Seen.held_pq = some(q)
    var round: int = 0
    for round < 16 {
        var p: int = 199
        for p >= 0 {
            pq_watch(q)
            q.push(p, p * 2)
            p -= 1
        }
        var seen: int = 0
        for seen < 200 {
            pq_watch(q)
            match q.pop() { some(v) => {} none => {} }
            seen += 1
        }
        round += 1
    }
    io.println("priorityqueue churn done: len {q.len()}")
    io.println("priorityqueue observed under collection: {Seen.pq_probes > 1000}")
}

// ---- part 6: SortedMap insert and remove, observed from a collector deinit --

// An in-place insert linked the new node deep in the tree and refreshed the
// root's cached `size` only on the way back up, so between the two `len()` read
// the old count while `contains_key` could already find the new key; a remove
// tore the other way. #92. The fix builds the changed spine fresh and publishes
// it with one `self.root = ...` store, so this probe must never see the count
// and the keys disagree.
//
// Every key ever inserted is in {0 .. 139}, so at any settled point len() is
// exactly the number of those keys `contains_key` answers true for — a
// self-relating invariant true for any subset and any round.
class SmProbe {
    peer: Option<SmProbe> = none
    owner: Option<collections.SortedMap<int, int>> = none
    pub fn init() {}
    fn deinit() {
        match self.owner {
            some(m) => {
                Seen.sm_probes += 1
                let n: int = m.len()
                var present: int = 0
                var k: int = 0
                for k < 140 {
                    if m.contains_key(k) { present += 1 }
                    k += 1
                }
                if n != present { Seen.torn_sm += 1 }
            }
            none => {}
        }
    }
}

fn sm_watch(m: collections.SortedMap<int, int>) {
    var a: SmProbe = new SmProbe()
    var b: SmProbe = new SmProbe()
    a.owner = some(m)
    b.owner = some(m)
    a.peer = some(b)
    b.peer = some(a)
}

fn sm_under_release() {
    var m: collections.SortedMap<int, int> = new()
    Seen.held_sm = some(m)
    var round: int = 0
    for round < 12 {
        // insert a scrambled permutation of 0..139
        var i: int = 0
        for i < 140 {
            let key: int = (i * 53 + 7) % 140
            sm_watch(m)
            m.set(key, key * 2)
            i += 1
        }
        // remove them again, scrambled the other way
        i = 0
        for i < 140 {
            let key: int = (i * 89 + 31) % 140
            sm_watch(m)
            m.remove(key)
            i += 1
        }
        round += 1
    }
    io.println("sortedmap churn done: len {m.len()}")
    io.println("sortedmap observed under collection: {Seen.sm_probes > 1000}")
}

fn main() {
    // The queue and the map churn first, while the heap is small and the
    // collector's threshold is low, so a collection lands *inside* a push, a
    // pop, an insert or a remove — where the tear would be — rather than only
    // after they settle. The deque parts follow; the crossover allocates enough
    // to collect on its own however large the heap has grown.
    pq_under_release()
    sm_under_release()
    clear_watching_deque()
    io.println("clear() seen mid-drop — deque tears {Seen.torn_deque}")
    panic_during_clear()
    reentrant_remove()
    crossover_under_release()
    io.println("consistent answers {Seen.answers} of 1")
    io.println("total tears {Seen.torn_deque + Seen.torn_pq + Seen.torn_sm}")
}
