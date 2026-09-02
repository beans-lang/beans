// A non-foldable initializer is refused with a message that names what was
// not constant — a call, a cast, a layout query, and every arithmetic
// result a backend could not reproduce. Grouped so one check proves the
// whole reason table, not one line of it.
import std.io

fn helper() -> int { return 1 }

const BAD_CALL: int = helper()
const BAD_CAST: int = 3.5 as int
const BAD_SIZEOF: int = size_of(int)
const BAD_DIV: int = 1 / 0
const BAD_MODZERO: int = 5 % 0
const BAD_SHIFT: i32 = 1 << 40
const BAD_U64: u64 = 1 << 63
// A u64 literal at or above 2^63 is a negative bit pattern in the fold's
// signed accumulator, so no operator may consume it — including a
// comparison, which would otherwise answer with signed order. Both
// spellings reach the same guard: the decimal one used to slip past it
// because `to_int()` answers i64's maximum instead of failing, and the
// fold then computed with a number the program never holds.
const U64_MAX_DEC: u64 = 18446744073709551615
const U64_MAX_HEX: u64 = 0xFFFFFFFFFFFFFFFF
const U64_HALF: u64 = 9223372036854775808
const BAD_U64_ADD: u64 = U64_MAX_DEC + 0
const BAD_U64_SHIFT: u64 = U64_MAX_DEC >> 1
const BAD_U64_AND: u64 = U64_MAX_DEC & 255
const BAD_U64_GT: bool = U64_MAX_DEC > 9223372036854775807
const BAD_U64_EQ: bool = U64_MAX_DEC == U64_HALF
const BAD_U64_HEX_ADD: u64 = U64_MAX_HEX + 0
const BAD_FLOAT: f64 = 1.5 + 2.5
const BAD_INTERP: string = "a{helper()}b"
const BAD_LIST: List<int> = [1, 2, 3]

fn main() {
    io.println("unreached")
}
