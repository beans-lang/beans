import std.io
import std.os

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("iterator")
    let n: int = args.get(1).or("").to_int().or(1_000_000)
    let seed: int = args.get(2).or("").to_int().or(1)
    let width: int = 8192
    var values: List<int> = []
    values.reserve(width)
    var index: int = 0
    for index < width {
        values.push((index * 31 + seed) % 1009)
        index += 1
    }
    let rounds: int = n / width
    var sum: int = 0
    var round: int = 0
    if mode == "iterator" {
        for round < rounds {
            for value: int in values {
                sum += value
            }
            round += 1
        }
    } else {
        for round < rounds {
            index = 0
            let count: int = values.len()
            for index < count {
                sum += values[index]
                index += 1
            }
            round += 1
        }
    }
    io.println(sum)
}
