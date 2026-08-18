// The path that did nothing cannot promise more than the path that wrote.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    let ok: bool = a.compare_exchange(0, 1, MemoryOrder.relaxed, MemoryOrder.seq_cst)
}
