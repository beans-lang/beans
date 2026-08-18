// A moved-from resource is gone. This is the check that makes a move-only handle
// safe: it is why a double close cannot be written.
unique class Slot {
    id: int
    fn init(id: int) { self.id = id }
    fn id_of() -> int { return self.id }
}

fn consume(move s: Slot) -> int { return s.id_of() }

fn main() {
    let s: Slot = new Slot(1)
    let first: int = consume(move s)
    let second: int = consume(move s)
}
