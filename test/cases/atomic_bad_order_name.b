// A typo should list the orders that exist.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    let v: i32 = a.load(MemoryOrder.consume)
}
