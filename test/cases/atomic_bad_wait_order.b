// wait re-reads the cell, so its order is a load order.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    a.wait(0, MemoryOrder.release)
}
