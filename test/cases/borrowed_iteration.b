// Borrowed list iteration must never outlive the element's slot.
// Every case here pins one hazard: structural mutation while the
// binding is live, closures capturing per-iteration values, bindings
// escaping into longer-lived storage, and aliased lists.
import std.io

class Item {
    value: int
    fn init(value: int) { self.value = value }
}

// The loop body clears the list while `item` is still live. The
// binding must keep the element alive: borrowing here would free the
// item before the field read.
fn mutation_during_iteration() {
    var items: List<Item> = [new Item(7)]
    for item: Item in items {
        items.clear()
        io.println("mutated {item.value}")
    }
}

// Pure read-only iteration: the safe case borrowing accelerates.
fn safe_sum() -> int {
    var items: List<Item> = []
    var index: int = 0
    for index < 100 {
        items.push(new Item(index))
        index += 1
    }
    var total: int = 0
    for item: Item in items {
        total += item.value
    }
    return total
}

// Map keys and values use the same proof. A read-only loop borrows both
// bindings and keeps the Map alive until the cursor is done.
fn safe_map_sum() -> int {
    var items: Map<string, Item> = {
        "one": new Item(1),
        "two": new Item(2),
        "three": new Item(3),
    }
    var total: int = 0
    for key: string, item: Item in items {
        total += key.len() + item.value
    }
    return total
}

// Replacing a value releases the Map's old reference. This binding must stay
// owned so the old item remains valid for the rest of this iteration.
fn mutation_during_map_iteration() {
    var items: Map<int, Item> = {1: new Item(7)}
    for key: int, item: Item in items {
        items[key] = new Item(9)
        io.println("map mutated {item.value}")
    }
}

// Each closure must keep its own iteration's element alive even after
// the list itself is cleared.
fn captured_bindings() {
    var items: List<Item> =
        [new Item(1), new Item(2), new Item(3)]
    var callbacks: List<fn() -> int> = []
    for item: Item in items {
        callbacks.push(fn() -> int { return item.value })
    }
    items.clear()
    var total: int = 0
    for callback: fn() -> int in callbacks {
        total += callback()
    }
    io.println("captured {total}")
}

// Elements pushed into longer-lived storage must survive the source
// list being cleared: the push takes its own reference.
fn escaped_bindings() {
    var items: List<Item> = [new Item(4), new Item(5)]
    var kept: List<Item> = []
    for item: Item in items {
        kept.push(item)
    }
    items.clear()
    var total: int = 0
    for item: Item in kept {
        total += item.value
    }
    io.println("escaped {total}")
}

fn main() {
    mutation_during_iteration()
    io.println("sum {safe_sum()}")
    io.println("map sum {safe_map_sum()}")
    mutation_during_map_iteration()
    captured_bindings()
    escaped_bindings()
}
