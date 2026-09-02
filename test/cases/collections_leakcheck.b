// std.collections under the macOS `leaks` sweep in test/sanitize.sh: every
// operation here frees what it drops, including SortedMap's structural remove.
// That removal used to be left out — it tripped the native ARC codegen leak
// filed as #60 — so the one path most likely to leak was the one path nothing
// swept. #60 has landed, collections_models.b joins the sweep alongside this
// file, and a leak from any of it is a real regression.
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

        // SortedMap: build, query and remove. The removal walks the owned
        // node tree and unlinks a node, which is the shape that leaked.
        map.set(value, step)
        if step % 6 == 0 { map.remove(value) }
        step += 1
    }

    // Deque past two full 512-blocks on each end, then drained both ways, so
    // the block map, both crossovers and the recycled spare are all built and
    // torn down under the leak sweep — the small churn above never leaves one
    // block. Every element is popped, so a leak here is a real regression.
    var big: collections.Deque<int> = new()
    var grow: int = 0
    for grow < 1300 {
        big.push_back(grow)
        big.push_front(-1 - grow)
        grow += 1
    }
    var pulled: int = 0
    var drained: int = 0
    for drained < 1300 {
        pulled += big.pop_front().or(0)
        drained += 1
    }
    for big.len() != 0 { pulled += big.pop_back().or(0) }

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
    sink += pulled
    sink += big.len()

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
