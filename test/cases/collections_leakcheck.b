// The leak-clean subset of std.collections, for the macOS `leaks` sweep in
// test/sanitize.sh: every operation here frees what it drops. Set, Deque and
// PriorityQueue remove through the builtin Map or List, which are leak-clean;
// SortedMap is built, queried and torn down but not removed from, because a
// structural remove from its owned node tree trips the native ARC codegen leak
// filed as #60. When #60 is fixed, collections_models.b (which does remove)
// joins the leaks sweep and this file can fold into it.
import std.io
import std.collections

fn exercise() {
    var seed: u64 = 0x2545f4914f6cdd1d

    var set: collections.Set<int> = new()
    var deque: collections.Deque<int> = new()
    var queue: collections.PriorityQueue<int, int> = new()
    var map: collections.SortedMap<int, int> = new()

    var step: int = 0
    for step < 4000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let value: int = (seed % 300) as int

        // Set: add and remove churn (Map-backed, leak-clean).
        set.add(value)
        if step % 3 == 0 { set.remove((seed >> 8) as int % 300) }

        // Deque: push both ends, pop both ends.
        if step % 2 == 0 { deque.push_front(value) } else { deque.push_back(value) }
        if step % 5 == 0 { deque.pop_front() }
        if step % 7 == 0 { deque.pop_back() }

        // PriorityQueue: push and pop (List-backed, leak-clean).
        queue.push(value % 50, step)
        if step % 4 == 0 { queue.pop() }

        // SortedMap: build and query only — no structural remove (see #60).
        map.set(value, step)
        step += 1
    }

    // Ordered queries hand back copies; the temporaries they build must free.
    var probe: int = 0
    var sink: int = 0
    for probe < 300 {
        sink += map.floor_key(probe).or(0)
        sink += map.ceiling_key(probe).or(0)
        sink += map.rank(probe)
        sink += map.range_keys(probe, probe + 20).len()
        probe += 1
    }
    sink += map.keys().len()
    sink += map.values().len()
    sink += set.items().len()
    sink += deque.to_list().len()

    // Set algebra allocates where the core operations do not: union_with clones
    // a whole map, and the other three build a fresh set by walking. Every
    // result here is a temporary whose length is read and then dropped, so the
    // leaks sweep sees the clone and the walked sets freed — including the
    // self-union, whose clone is walked against its own source.
    var other: collections.Set<int> = new()
    var pick: int = 0
    for pick < 150 {
        other.add(pick * 2)
        pick += 1
    }
    sink += set.union_with(other).len()
    sink += set.intersection(other).len()
    sink += set.difference(other).len()
    sink += set.symmetric_difference(other).len()
    sink += set.union_with(set).len()

    io.println("ok {set.len()} {deque.len()} {queue.len()} {map.len()} {sink}")
}

fn main() {
    // Run the whole thing inside a called frame so every container is dropped
    // before exit; the leaks sweep then sees teardown, not still-reachable state.
    exercise()
}
