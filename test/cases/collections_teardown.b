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
//
// The rule both break is the one the runtime containers already follow:
// a container is settled before it drops anything, and it stays usable after a
// contained panic. `List` and `Map` are printed alongside as the reference.
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

// ---- part 4: the crossover, observed from an element being dropped --------

class CrossWatcher {
    owner: Option<collections.Deque<int>> = none
    expect: int = 0
    pub fn init() {}
    fn deinit() {
        match self.owner {
            some(d) => { if d.len() != self.expect { Seen.torn_deque += 1 } }
            none => {}
        }
    }
}

// Crossover churn with objects being released throughout: every pop here comes
// off the empty end, so each one rebalances. This is coverage of the crossover
// under concurrent release, not a guard on any specific defect — nothing in it
// fails today whether the crossover's allocations are hoisted out of its
// stale-counter window or not.
fn crossover_under_release() {
    var d: collections.Deque<int> = new()
    var round: int = 0
    for round < 40 {
        var i: int = 0
        for i < 1300 { d.push_back(i); i += 1 }
        // Drain from the empty end so every pop crosses over.
        var seen: int = 0
        for seen < 1300 {
            var w: CrossWatcher = new CrossWatcher()
            w.owner = some(d)
            w.expect = d.len()
            match d.pop_front() { some(v) => {} none => {} }
            w.expect = d.len()
            seen += 1
        }
        round += 1
    }
    io.println("crossover churn done: len {d.len()}")
}

fn main() {
    clear_watching_deque()
    io.println("clear() seen mid-drop — deque tears {Seen.torn_deque}")
    panic_during_clear()
    reentrant_remove()
    crossover_under_release()
    io.println("consistent answers {Seen.answers} of 1")
    io.println("total tears {Seen.torn_deque}")
}
