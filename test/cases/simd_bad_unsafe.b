// Vectors are raw hardware.
fn main() {
    let v: Simd4i32 = Simd4i32.splat(1)
    let sum: i32 = v.sum()
}
