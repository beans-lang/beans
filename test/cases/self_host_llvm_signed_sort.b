// narrow integers ride the runtime slot: signed types must
// sign-extend on the way in or the runtime's i64 ordering puts
// -2 after 1, while unsigned types keep zero-extension so 200u8
// still beats 5u8. Sorting, min/max, and map lookups all cross
// that boundary.
import std.io

fn main() {
    var bytes: List<i8> = [1 as i8, -2 as i8, 0 as i8]
    bytes.sort()
    io.println("{bytes[0]} {bytes[1]} {bytes[2]}")

    var shorts: List<i16> = [-300 as i16, 5 as i16, -2 as i16]
    shorts.sort()
    io.println("{shorts[0]} {shorts[1]} {shorts[2]}")

    var words: List<i32> = [7 as i32, -100000 as i32, 0 as i32]
    words.sort()
    io.println("{words[0]} {words[1]} {words[2]}")

    var unsigned: List<u8> = [200 as u8, 5 as u8, 100 as u8]
    unsigned.sort()
    io.println("{unsigned[0]} {unsigned[1]} {unsigned[2]}")

    var table: Map<i8, string> = {}
    table[-3 as i8] = "neg"
    table[3 as i8] = "pos"
    io.println("{table[-3 as i8]} {table[3 as i8]}")
}
