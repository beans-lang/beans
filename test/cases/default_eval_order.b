import std.io

class LoudDefault {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("close {self.name}")
    }
}

fn make_loud(name: string) -> LoudDefault {
    io.println("build {name}")
    return new LoudDefault(name)
}

struct DefaultPair {
    first: LoudDefault = make_loud("default first")
    second: LoudDefault = make_loud("default second")
}

fn main() {
    let pair: DefaultPair = DefaultPair {
        first: make_loud("explicit first")
    }
    io.println("live {pair.first.name} / {pair.second.name}")
}
