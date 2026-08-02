// An alignment that is not a power of two. Both backends must panic with the
// same message, at the same place, with the same exit code.
import std.io

extern "C" align(64) struct Wide {
    seq: u32
}

fn main() {
    unsafe {
        let p: RawPtr<Wide> = RawPtr.alloc_aligned(1, 24)
        io.println("unreachable {p.is_null()}")
    }
}
