import std.io

class Base {
    priv fn secret() -> int {
        return 11
    }

    priv static fn seed() -> int {
        return 3
    }

    fn reveal() -> int {
        return self.secret()
    }

    static fn reveal_seed() -> int {
        return Base.seed()
    }
}

class Child extends Base {
    // This is a new method. It does not replace Base.secret.
    fn secret() -> int {
        return 99
    }

    fn reveal_child() -> int {
        return self.secret()
    }
}

class PrivateConstructor {
    priv value: int

    priv fn init(value: int) {
        self.value = value
    }

    static fn make(value: int) -> PrivateConstructor {
        return new PrivateConstructor(value)
    }

    fn read() -> int {
        return self.value
    }
}

struct Counter {
    priv value: int

    priv fn read() -> int {
        return self.value
    }

    priv inout fn add(amount: int) {
        self.value += amount
    }

    priv static fn initial() -> int {
        return 4
    }

    static fn make() -> Counter {
        return Counter { value: Counter.initial() }
    }

    fn current() -> int {
        return self.read()
    }

    inout fn advance(amount: int) {
        self.add(amount)
    }
}

fn main() {
    let child: Child = new Child()
    let base: Base = child
    io.println("{base.reveal()}:{child.reveal()}:{child.reveal_child()}")
    io.println("{Base.reveal_seed()}")

    let made: PrivateConstructor = PrivateConstructor.make(17)
    io.println("{made.read()}")

    var counter: Counter = Counter.make()
    io.println("{counter.current()}")
    counter.advance(2)
    io.println("{counter.current()}")
}
