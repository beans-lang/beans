// Range-loop cases both compilers can build natively today. Inclusive
// ranges ending at a type's maximum live in self_host_llvm_range.b:
// the stage-0 counted loop still wraps past the bound there, so those
// run native only through the self-hosted build.
import std.io

fn endpoint() -> int {
    io.println("endpoint evaluated")
    return 4
}

fn main() {
    var inclusive_sum: int = 0
    for value: int in 1..=5 {
        inclusive_sum += value
    }
    io.println("inclusive {inclusive_sum}")

    var exclusive_sum: int = 0
    for value: int in 2..5 {
        exclusive_sum += value
    }
    io.println("exclusive {exclusive_sum}")

    var empty_exclusive: int = 0
    for value: int in 5..5 {
        empty_exclusive += 1
    }
    io.println("empty_exclusive {empty_exclusive}")

    var empty_inclusive: int = 0
    for value: int in 5..=4 {
        empty_inclusive += 1
    }
    io.println("empty_inclusive {empty_inclusive}")

    var negative_sum: int = 0
    for value: int in -3..=-1 {
        negative_sum += value
    }
    io.println("negative {negative_sum}")

    let low: u8 = 10
    let high: u8 = 13
    var unsigned_sum: int = 0
    for value: u8 in low..high {
        unsigned_sum += value as int
    }
    io.println("unsigned {unsigned_sum}")

    var steered: int = 0
    for value: int in 1..=10 {
        if value == 3 { continue }
        if value == 6 { break }
        steered += value
    }
    io.println("steered {steered}")

    var once_sum: int = 0
    for value: int in 1..=endpoint() {
        once_sum += value
    }
    io.println("once {once_sum}")
}
