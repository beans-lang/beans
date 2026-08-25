// A generic interface used the two ways that used to be refused: a class
// pinning a concrete argument at the implements site, and the interface
// itself standing as a variable type. Both dispatch dynamically, so the
// interpreter, a debug build and a release build must agree line for line.
import std.io

pub interface Producer<T> {
    fn make() -> T
    // a default the implementor may keep, written in the interface's own
    // type parameter so the instantiation has to bind it
    fn twice() -> List<T> { return [self.make(), self.make()] }
    fn label() -> string { return "producer" }
}

// the concrete binding at the implements site
pub class IntBox implements Producer<int> {
    pub fn init() {}
    pub fn make() -> int { return 7 }
}

pub class NameBox implements Producer<string> {
    pub fn init() {}
    pub fn make() -> string { return "beans" }
    pub override fn label() -> string { return "names" }
}

// the pass-through, instantiated at two different arguments
pub class BoxOf<T> implements Producer<T> {
    pub value: T
    pub fn init(value: T) { self.value = value }
    pub fn make() -> T { return self.value }
}

// a chain: the concrete argument is pinned one link up
pub interface IntProducer extends Producer<int> {
    fn describe() -> string { return "ints" }
}

pub class Seven implements IntProducer {
    pub fn init() {}
    pub fn make() -> int { return 7 }
}

pub fn read_int(p: Producer<int>) -> int {
    return p.make()
}

fn main() {
    let a: Producer<int> = new IntBox()
    let b: Producer<string> = new NameBox()
    let c: Producer<int> = new BoxOf<int>(3)
    let d: Producer<string> = new BoxOf<string>("box")

    io.println("{a.make()} {b.make()} {c.make()} {d.make()}")
    io.println("{a.label()} {b.label()} {c.label()}")
    io.println("{a.twice().len()} {c.twice()[1]} {d.twice()[0]}")
    io.println("{read_int(a)} {read_int(c)}")

    let e: IntProducer = new Seven()
    let f: Producer<int> = new Seven()
    io.println("{e.make()} {e.describe()} {f.make()} {read_int(e)}")

    var all: List<Producer<int>> = [a, c, e]
    var total: int = 0
    for p: Producer<int> in all {
        total += p.make()
    }
    io.println("total {total}")
}
