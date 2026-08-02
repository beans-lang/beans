import std.io

fn apply_twice(callback: fn(int) -> int, seed: int) -> int {
    return callback(callback(seed))
}

fn counter_pair() -> fn() -> int {
    var count: int = 0
    let bump: fn() -> int = fn() -> int {
        count += 2
        return count
    }
    count = 10
    return bump
}

fn main() {
    let plain: fn(int) -> int = fn(value: int) -> int { return value * 3 + 1 }
    io.println("plain {plain(4)} twice {apply_twice(plain, 2)}")

    let offset: int = 7
    let shifted: fn(int) -> int = fn(value: int) -> int { return value + offset }
    io.println("captured {shifted(10)}")

    var total: int = 0
    let add: fn(int) = fn(amount: int) { total += amount }
    add(3)
    add(4)
    io.println("mutated {total}")

    var label: string = "start"
    let rename: fn() = fn() { label = "{label}-done" }
    rename()
    io.println("shared {label}")

    let ticker: fn() -> int = counter_pair()
    io.println("escaped {ticker()} {ticker()}")

    var callbacks: List<fn() -> int> = []
    for index: int in 0..3 {
        let held: int = index * 5
        callbacks.push(fn() -> int { return held })
    }
    var sum: int = 0
    for callback: fn() -> int in callbacks {
        sum += callback()
    }
    io.println("loop cells {sum}")

    var names: List<string> = []
    names.push("beans")
    let describe: fn() -> string = fn() -> string {
        return "held {names.len()} names"
    }
    names.push("brew")
    io.println(describe())
}
