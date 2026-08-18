// A load publishes nothing, so it has nothing to release.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    let v: i32 = a.load(MemoryOrder.release)
}
