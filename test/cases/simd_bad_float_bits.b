// There is no meaningful bitwise-and of two floats.
fn main() {
    unsafe {
        let f: Simd4f32 = Simd4f32.splat(1.0)
        let bad: Simd4f32 = f.bit_and(f)
    }
}
