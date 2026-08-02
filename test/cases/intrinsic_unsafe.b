// Intrinsics are raw hardware.
import std.intrinsic
fn main() {
    let v: int = intrinsic.popcount(255)
}
