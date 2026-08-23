import std.io

interface Reader {
    fn doubled() -> int
}

class ReadOnly implements Reader {
    value: int

    fn init(value: int) {
        self.value = value
    }

    fn doubled() -> int {
        return self.value * 2
    }
}

fn safe_stack() -> int {
    let concrete: ReadOnly = new ReadOnly(9)
    let reader: Reader = concrete
    return reader.doubled()
}

interface Adjuster {
    fn bump()
}

class Mutable implements Adjuster {
    value: int

    fn init(value: int) {
        self.value = value
    }

    fn bump() {
        self.value += 1
    }

    fn get() -> int {
        return self.value
    }
}

fn mutating_fallback() -> int {
    let concrete: Mutable = new Mutable(4)
    let adjuster: Adjuster = concrete
    adjuster.bump()
    return concrete.get()
}

fn main() {
    io.println(safe_stack())
    io.println(mutating_fallback())
}
