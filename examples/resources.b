// Move-only resources: the shape every OS handle in `std` uses.
//
// A `unique class` cannot be copied. Combined with `deinit` it gives a handle that
// exactly one place owns and that closes at a knowable moment — which is what an
// open file, a socket or a child process needs.
//
// Three rules follow from `unique`, and they are the reason this file exists: they
// are worth seeing in one place before reading any resource API.

import std.io

// An owned resource. `deinit` runs when the last reference goes away, and because
// the value is move-only there is only ever one.
unique class Slot {
    id: int
    closed: bool = false

    fn init(id: int) {
        self.id = id
    }

    fn deinit() {
        // Deterministic, and observable — that is the point of a resource type.
        io.println("slot {self.id} closed")
    }

    fn id_of() -> int {
        return self.id
    }

    fn close() {
        self.closed = true
    }
}

// Acquiring can fail, so it returns a Result. This is the signature every resource
// in `std` has.
fn open_slot(id: int) -> Result<Slot> {
    if id < 0 {
        return err("slot id must not be negative")
    }
    return ok(new Slot(id))
}

// `?` unwraps the Result into an *owned* local. That is how a resource is taken out
// of a Result — a `match` binding borrows instead, so it can read the resource but
// not take it.
fn use_two() -> Result<int> {
    let first: Slot = open_slot(1)?
    let second: Slot = open_slot(2)?
    return ok(first.id_of() + second.id_of())
}

// A `move` parameter takes ownership, so the resource closes here rather than in the
// caller.
fn consume(move slot: Slot) -> int {
    return slot.id_of()
}

fn hand_over() -> Result<int> {
    let slot: Slot = open_slot(3)?
    return ok(consume(move slot))
}

// A failure part-way through still closes what was already opened.
fn fails_late() -> Result<int> {
    let good: Slot = open_slot(4)?
    let bad: Slot = open_slot(-1)?
    return ok(good.id_of() + bad.id_of())
}

fn main() {
    // Two resources, closed newest-first at the end of the function that owns them.
    match use_two() {
        ok(total) => io.println("used two, total {total}"),
        err(e) => io.println("failed {e.msg}"),
    }

    // Ownership handed to a `move` parameter: the close happens inside the callee.
    match hand_over() {
        ok(id) => io.println("handed over {id}"),
        err(e) => io.println("failed {e.msg}"),
    }

    // The error path. Slot 4 was already open when slot -1 failed, and it still
    // closes — a leak here would be a resource left open on an error return, which
    // is the single most common bug this shape exists to prevent.
    match fails_late() {
        ok(total) => io.println("unexpected {total}"),
        err(e) => io.println("failed as expected: {e.msg}"),
    }

    // A match arm *borrows* the payload, so it can be read but not moved out.
    match open_slot(5) {
        ok(slot) => io.println("borrowed slot {slot.id_of()}"),
        err(e) => io.println("failed {e.msg}"),
    }

    io.println("done")
}
