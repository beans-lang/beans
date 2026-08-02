// The order becomes part of the instruction, so it cannot come from a variable.
fn main() {
    let a: Atomic<i32> = new Atomic<i32>(0)
    let picked: MemoryOrder = MemoryOrder.acquire
    let v: i32 = a.load(picked)
}
