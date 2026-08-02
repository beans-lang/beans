import std.io

struct Pair {
    left: i32
    right: i32
}

fn shift(value: Option<Pair>) -> Option<Pair> {
    let pair: Pair = value?
    return some(Pair {
        left: pair.left + 1,
        right: pair.right + 1,
    })
}

fn main() {
    let pair: Pair = Pair { left: 4, right: 8 }
    let present: Option<Pair> = some(pair)
    let mapped: Option<Pair> = present.map(
        fn(value: Pair) -> Pair {
            return Pair {
                left: value.left + 2,
                right: value.right + 3,
            }
        })
    let filtered: Option<Pair> = present.filter(
        fn(value: Pair) -> bool {
            return value.right == 8
        })
    io.println("option {present == some(pair)} {mapped.expect("map").right} {filtered.is_some()} {shift(present).expect("shift").left}")

    let good: Result<Pair> = ok(pair)
    let result: Result<Pair> = good.map(
        fn(value: Pair) -> Pair {
            return Pair {
                left: value.left + 5,
                right: value.right + 5,
            }
        })
    let wide_error: Result<int, [i32; 4]> =
        err([7, 8, 9, 10])
    let recovered: int = wide_error.recover(
        fn(error: [i32; 4]) -> int {
            return error[2] as int
        })
    io.println("result {good == ok(pair)} {result.expect("map").left} {wide_error.is_ok()} {recovered}")
}
