// fma takes three operands, not two.
import std.intrinsic
fn main() {
    unsafe {
        let v: float = intrinsic.fma(2.0, 3.0)
    }
}
