// Only what the machine can read and write atomically in one instruction.
fn main() {
    let a: Atomic<f64> = new Atomic<f64>(1.0)
    let b: Atomic<string> = new Atomic<string>("no")
}
