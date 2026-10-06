import std.io

fn first_signed() -> int {
    for value: int in 7..9223372036854775807 {
        return value
    }
    return -1
}

fn first_unsigned() -> u64 {
    let start: u64 = 9
    let end: u64 = 18446744073709551615
    for value: u64 in start..=end {
        return value
    }
    return 0
}

fn main() {
    for value: int in 0..=9223372036854775807 {
        io.println("signed break {value}")
        break
    }
    let start: u64 = 0
    let end: u64 = 18446744073709551615
    for value: u64 in start..end {
        io.println("unsigned break {value}")
        break
    }
    io.println("signed return {first_signed()}")
    io.println("unsigned return {first_unsigned()}")
}
