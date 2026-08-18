import std.io

fn fib(n: int) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    var inclusive_sum: int = 0
    for value: int in 1..=5 {
        inclusive_sum += value
    }

    var exclusive_sum: int = 0
    for value: int in 2..5 {
        exclusive_sum += value
    }

    var empty_count: int = 0
    for value: int in 5..5 {
        empty_count += value
    }

    var maximum_count: int = 0
    for value: int in 9223372036854775807..=9223372036854775807 {
        maximum_count += 1
        io.println(value)
    }

    let unsigned_low: u8 = 254
    let unsigned_high: u8 = 255
    var unsigned_sum: int = 0
    for value: u8 in unsigned_low..=unsigned_high {
        unsigned_sum += value as int
    }

    var near_maximum: int = 0
    for value: int in
        9223372036854775806..=9223372036854775807 {
        near_maximum += 1
    }

    let wide_low: u64 = 18446744073709551614
    let wide_high: u64 = 18446744073709551615
    var wide_count: int = 0
    for value: u64 in wide_low..=wide_high {
        wide_count += 1
    }

    io.println(inclusive_sum)
    io.println(exclusive_sum)
    io.println(empty_count)
    io.println(maximum_count)
    io.println(unsigned_sum)
    io.println(near_maximum)
    io.println(wide_count)
    io.println(fib(10))
}
