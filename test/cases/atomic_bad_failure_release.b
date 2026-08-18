// A failed compare_exchange performs no write, so its order cannot release.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    let ok: bool = a.compare_exchange(0, 1, MemoryOrder.seq_cst, MemoryOrder.release)
}
