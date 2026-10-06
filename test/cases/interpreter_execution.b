import std.io
import std.thread

fn bump(inout value: int) -> int {
    value += 3
    return value
}

// Identical source spellings can have different widths and scalar kinds.
// Repeated calls must decode the same payload without sharing mutable values.
fn literals() -> int {
    var narrow: u8 = 0xFF
    var wide: u64 = 0xFF
    narrow += 1
    wide += 1
    if narrow != 0 || wide != 256 { panic("integer literal width") }
    var signed: i8 = 127
    var larger: int = 127
    signed += 1
    larger += 1
    if signed != -128 || larger != 128 { panic("signed literal width") }

    let small: f32 = 16_777_217.0
    let large: f64 = 16_777_217.0
    let exact: decimal = 16_777_217.0
    if (small as int) != 16777216 ||
       (large as int) != 16777217 ||
       (exact as int) != 16777217 { panic("literal scalar kind") }
    let based_float: f64 = 0b101
    let based_decimal: decimal = 0xFF
    if based_float != 5.0 || based_decimal != 255 {
        panic("based literal")
    }
    let fixed: string = "a\tb\n\"c\""
    if fixed.len() != 7 { panic("string escapes") }

    var count: int = 1
    let read: fn() -> int = fn() -> int { return count }
    let mutate: fn() -> int = fn() -> int { return bump(inout count) }
    let first: string = "count {mutate()}"
    let second: string = "count {mutate()}"
    if first != "count 4" || second != "count 7" || read() != 7 {
        panic("interpolation or captured inout")
    }
    return count
}

fn main() {
    var total: int = 0
    var turn: int = 0
    for turn < 8 {
        total += literals()
        turn += 1
    }
    // Threads interpret the same checked HIR with their own decode caches.
    let left: Thread<int> = thread.spawn(fn() -> int { return literals() })
    let right: Thread<int> = thread.spawn(fn() -> int { return literals() })
    total += left.join()
    total += right.join()
    io.println("execution {total}")
}
