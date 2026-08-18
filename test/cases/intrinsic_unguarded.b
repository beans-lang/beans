// A feature-gated intrinsic needs the same guard a feature-marked function does.
import std.intrinsic
fn main() {
    unsafe {
        let v: int = intrinsic.crc32c(0, 1)
    }
}
