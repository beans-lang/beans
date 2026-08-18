import std.io

extern "C" fn srand(seed: u32)

fn main() {
    unsafe {
        srand(1)
    }
    io.println("ffi void")
}
