import std.io
import std.os

fn add_offset(value: int, offset: int) -> int {
    return value + offset
}

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("closure")
    let n: int = args.get(1).or("").to_int().or(1_000_000)
    let seed: int = args.get(2).or("").to_int().or(1)
    let offset: int = seed % 97
    var sum: int = 0
    var index: int = 0
    if mode == "closure" {
        let operation: fn(int) -> int =
            fn(value: int) -> int { return value + offset }
        for index < n {
            sum += operation(index % 1009)
            index += 1
        }
    } else {
        for index < n {
            sum += add_offset(index % 1009, offset)
            index += 1
        }
    }
    io.println(sum)
}
