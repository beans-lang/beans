// A lane index outside the vector panics identically in both backends.
import std.io
fn main() {
    unsafe {
        let v: Simd4i32 = Simd4i32.of(1, 2, 3, 4)
        var at: int = 2
        at += 2
        io.println("lane {v.lane(at)}")
    }
}
