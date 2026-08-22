import std.io
import std.os

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("safe")
    let n: int = args.get(1).or("").to_int().or(1_000_000)
    let seed: int = args.get(2).or("").to_int().or(1)
    let width: int = 8192
    var sum: int = 0
    unsafe {
        let storage: RawPtr<i32> = RawPtr.alloc(width)
        var index: int = 0
        for index < width {
            storage.offset(index).write(
                ((index * 31 + seed) % 1009) as i32)
            index += 1
        }
        let view: Slice<i32> = Slice.from_raw(storage, width)
        let rounds: int = n / width
        var round: int = 0
        if mode == "safe" {
            for round < rounds {
                index = 0
                for index < view.len() {
                    sum += view[index] as int
                    index += 1
                }
                round += 1
            }
        } else {
            for round < rounds {
                index = 0
                for index < width {
                    sum += storage.offset(index).read() as int
                    index += 1
                }
                round += 1
            }
        }
        storage.free()
    }
    io.println(sum)
}
