import std.io
import std.os

fn choose<T>(left: T, right: T, take_left: bool) -> T {
    if take_left { return left }
    return right
}

fn choose_int(left: int, right: int, take_left: bool) -> int {
    if take_left { return left }
    return right
}

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("generic")
    let n: int = args.get(1).or("").to_int().or(1_000_000)
    let seed: int = args.get(2).or("").to_int().or(1)
    var sum: int = 0
    var index: int = 0
    if mode == "generic" {
        for index < n {
            sum += choose(
                (index + seed) % 1009,
                (index * 3 + seed) % 1013,
                index % 2 == 0)
            index += 1
        }
    } else {
        for index < n {
            sum += choose_int(
                (index + seed) % 1009,
                (index * 3 + seed) % 1013,
                index % 2 == 0)
            index += 1
        }
    }
    io.println(sum)
}
