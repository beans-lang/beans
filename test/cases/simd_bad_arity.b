// `of` takes one argument per lane, so the arity is the shape.
fn main() {
    unsafe {
        let v: Simd4i32 = Simd4i32.of(1, 2)
    }
}
