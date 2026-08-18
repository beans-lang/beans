// A shift at or past the element width is undefined natively, so it panics.
import std.io
fn main() {
    unsafe {
        let v: Simd4i32 = Simd4i32.splat(1)
        var by: int = 16
        by += 16
        io.println("shl {v.shl(by).lane(0)}")
    }
}
