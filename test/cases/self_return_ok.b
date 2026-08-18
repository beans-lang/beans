import std.io

interface Tunable {
    fn tune(n: int) -> Self
    fn reading() -> int
}

class Base implements Tunable {
    value: int = 0
    pub override fn tune(n: int) -> Self {
        self.value = self.value + n
        return self
    }
    pub override fn reading() -> int { return self.value }
    pub fn twice() -> Self {
        return self.tune(self.value)
    }
}

class Special extends Base {
    pub fn only_here() -> int { return self.value * 100 }
    pub fn boosted(n: int) -> Self {
        super.tune(n * 2)
        return self
    }
}

class Holder<T> {
    items: List<T> = []
    pub fn keep(move item: T) -> Self {
        self.items.push(move item)
        return self
    }
    pub fn count() -> int { return self.items.len() }
}

fn main() {
    io.println("chain {new Special().tune(1).tune(2).only_here()}")
    io.println("twice {new Special().tune(3).twice().only_here()}")
    io.println("super {new Special().boosted(2).tune(1).only_here()}")
    let iface: Tunable = new Base()
    io.println("iface {iface.tune(9).reading()}")
    io.println("generic {new Holder<int>().keep(1).keep(2).keep(3).count()}")
}
