// The allowlist is closed: an unknown name is an error listing what exists.
import std.intrinsic
fn main() {
    unsafe {
        let v: int = intrinsic.vpternlogd(1, 2, 3)
    }
}
