import std.io

fn greet(name: string, punct: string = "!", times: int = 1) -> string {
    var parts: List<string> = []
    for index: int in 0..times {
        parts.push("{name}{punct}")
    }
    return parts.join(" ")
}

class Pad {
    width: int = 0
    static fn make(width: int = 4) -> Pad {
        let made: Pad = new Pad()
        made.width = width
        return made
    }
    pub fn grow(by: int = 2) -> int {
        self.width = self.width + by
        return self.width
    }
}

fn pick<T>(value: T, keep: bool = true) -> Option<T> {
    if keep { return some(value) }
    return none
}

fn maybe(label: string, fallback: Option<int> = none) -> int {
    return fallback.or(label.len())
}

fn main() {
    io.println(greet("hi"))
    io.println(greet("yo", "?"))
    io.println(greet("go", ".", 3))
    let pad: Pad = Pad.make()
    io.println("{pad.grow()} {pad.grow(10)} {Pad.make(9).width}")
    io.println("{pick(5).or(-1)} {pick(7, false).or(-1)}")
    io.println("{maybe("beans")} {maybe("beans", some(2))}")
}
