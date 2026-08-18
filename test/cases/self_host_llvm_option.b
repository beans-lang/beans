import std.io

fn choose(value: int, present: bool) -> Option<int> {
    if present {
        return some(value)
    }
    return none
}

fn word(present: bool) -> Option<string> {
    if present {
        return some("yes")
    }
    return none
}

fn main() {
    match choose(7, true) {
        some(value) => io.println(value),
        none => io.println(0),
    }
    match word(true) {
        some(value) => io.println(value),
        none => io.println("missing"),
    }
    match some([4, 5]) {
        some(values) => io.println(values[1]),
        none => io.println(0),
    }

    io.println(choose(7, false).or(9))
    io.println(word(true).or("no"))
    io.println(word(false).or("no"))

    let values: List<int> = [4, 5]
    io.println(values.get(0).or(9))
    io.println(values.get(3).or(9))
    let words: List<string> = ["yes"]
    io.println(words.get(0).or("no"))
    io.println(words.get(3).or("no"))
}
