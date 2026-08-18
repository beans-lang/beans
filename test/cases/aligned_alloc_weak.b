// An alignment weaker than the element type's own. Upgrading it silently would
// hide the mistake, so this is a panic rather than a courtesy.
import std.io

extern "C" align(64) struct Wide {
    seq: u32
}

fn main() {
    unsafe {
        let p: RawPtr<Wide> = RawPtr.alloc_aligned(1, 8)
        io.println("unreachable {p.is_null()}")
    }
}
