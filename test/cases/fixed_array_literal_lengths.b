// A fixed array's length is an integer literal, and an integer literal in
// Beans is decimal, hex, binary, or any of those with digit separators. The
// length position used to read it with the string-to-int conversion instead
// of the language's own literal parser, so `[int; 0x4]` and `[int; 1_0]`
// panicked the compiler rather than meaning 4 and 10.
import std.io

struct Packed {
    hex: [u8; 0x8]
    binary: [u8; 0b110]
    separated: [u8; 1_6]
}

fn last_hex(values: [int; 0xA]) -> int { return values[0x9] }

fn main() {
    let hex: [int; 0x4] = [1, 2, 3, 4]
    let upper: [int; 0X5] = [1, 2, 3, 4, 5]
    let binary: [int; 0b111] = [1, 2, 3, 4, 5, 6, 7]
    let separated: [int; 1_0] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    let hex_separated: [int; 0x1_0] = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]
    io.println("lengths {hex[3]} {upper[4]} {binary[6]} {separated[9]} {hex_separated[15]}")
    io.println("sizes {size_of(Packed)} {size_of([u8; 0x10])} {size_of([u8; 1_0])}")
    io.println("signature {last_hex([1, 2, 3, 4, 5, 6, 7, 8, 9, 100])}")
}
