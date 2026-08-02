// 256-bit needs a target and feature set that has 256-bit registers.
fn main() {
    unsafe {
        let wide: Simd8i32 = Simd8i32.splat(1)
    }
}
