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
const BAD_FLOAT: f64 = 1.5 + 2.5
const BAD_INTERP: string = "a{helper()}b"
const BAD_LIST: List<int> = [1, 2, 3]

fn main() {
    io.println("unreached")
}
