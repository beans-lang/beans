import std.io

// Two 32-bit integer arguments in one checked extern: the exact signature
// whose widened words a 32-bit host used to split into shifted argument
// slots, making _rotl read its shift from the high half of value. Both
// symbols are msvcrt.dll/ucrtbase.dll exports, which is all the Windows
// module walk can resolve.
extern "C" fn _rotl(value: u32, shift: i32) -> u32
extern "C" fn _rotr(value: u32, shift: i32) -> u32

fn main() {
    unsafe {
        io.println("{_rotl(2147483649, 1)} {_rotr(3, 1)}")
    }
}
