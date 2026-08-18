// A match binding borrows, so a move-only payload cannot be moved out of an arm.
// The way to take ownership is `?`, which is what every resource API uses.
unique class Slot {
    id: int
    fn init(id: int) { self.id = id }
    fn id_of() -> int { return self.id }
}

fn open_slot() -> Result<Slot> { return ok(new Slot(1)) }
fn consume(move s: Slot) -> int { return s.id_of() }

fn main() {
    match open_slot() {
        ok(s) => consume(move s),
        err(e) => 0,
    }
}
