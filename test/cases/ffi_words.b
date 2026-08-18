import std.io

// The interpreter's direct word path widens every extern argument to one
// 8-byte word, which a 32-bit host splits across two native argument
// slots. These are the shapes that used to read shifted slots there: the
// pointer pair and the pointer-plus-int must reach the C ABI bridge with
// their declared widths, while the lone narrow argument stays on the word
// path. Every symbol is a real CRT export everywhere the interpreter runs
// (glibc, musl, libSystem, msvcrt.dll, ucrtbase.dll) — the Windows module
// walk cannot see static-CRT symbols.
extern "C" fn abs(value: i32) -> i32
extern "C" fn strcmp(left: RawPtr<u8>, right: RawPtr<u8>) -> i32
extern "C" fn strchr(text: RawPtr<u8>, wanted: i32) -> RawPtr<u8>

fn main() {
    unsafe {
        let left: RawPtr<u8> = RawPtr.alloc(3)
        left.write(66)
        left.offset(1).write(88)
        left.offset(2).write(0)
        let right: RawPtr<u8> = RawPtr.alloc(3)
        right.write(66)
        right.offset(1).write(89)
        right.offset(2).write(0)
        io.println("abs {abs(-5)}")
        let same: bool = strcmp(left, left) == 0
        let less: bool = strcmp(left, right) < 0
        let more: bool = strcmp(right, left) > 0
        io.println("strcmp {same} {less} {more}")
        let hit: RawPtr<u8> = strchr(left, 88)
        let missing: RawPtr<u8> = strchr(left, 90)
        let missed: bool = missing == RawPtr.null()
        io.println("strchr {hit.read()} {missed}")
        left.free()
        right.free()
    }
}
