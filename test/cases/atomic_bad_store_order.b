// A store observes nothing, so it has nothing to acquire.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    a.store(1, MemoryOrder.acq_rel)
}
