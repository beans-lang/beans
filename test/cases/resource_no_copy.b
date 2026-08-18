// A unique value has no copy, so a plain second binding is rejected.
unique class Slot {
    id: int
    fn init(id: int) { self.id = id }
}

fn main() {
    let a: Slot = new Slot(1)
    let b: Slot = a
}
