import std.io

singleton class Counter {
    priv value: int = 10

    fn init() {
        io.println("init")
    }

    fn next() -> int {
        self.value += 1
        return self.value
    }

    fn current() -> int {
        return self.value
    }
}

class SingletonStaticRead {
    // Static initialization is allowed to force the singleton dependency.
    static initial: int = Counter.instance.current()
}

fn main() {
    let first: Counter = Counter.instance
    let second: Counter = Counter.instance
    io.println("{SingletonStaticRead.initial}")
    io.println("{first.next()}")
    io.println("{second.next()}")
}
