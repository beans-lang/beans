import std.intrinsic
import std.io

fn main() {
    unsafe {
        let block: RawPtr<u8> = RawPtr.alloc(16)
        intrinsic.prefetch(block)
        intrinsic.spin_hint()
        block.free()
    }
    io.println("hints are safe to ignore")
}
