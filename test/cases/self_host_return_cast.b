import std.io

interface Numbered {
    fn number() -> int
}

class BoxedNumber implements Numbered {
    value: int

    fn init(value: int) {
        self.value = value
    }

    fn number() -> int {
        return self.value
    }
}

fn make_number(first: bool) -> Numbered {
    if first {
        return (new BoxedNumber(7)) as Numbered
    }
    return (new BoxedNumber(9)) as Numbered
}

fn main() {
    io.println(make_number(true).number())
    io.println(make_number(false).number())
}
