// The order an object releases its fields is program-visible: the object's
// own class first, fields in reverse declaration order, then each base class
// up the chain. A field's declared type does not change that — a generic
// parameter, an Option, a Result, a List, a Map, a struct and an interface
// all hold the last reference to something with a deinit just as a bare class
// name does (issue #82).
//
// Field defaults evaluate in the same order the fields sit in: base class
// first, declaration order within each class.
import std.io

class Loud {
    id: int = 0

    pub fn init(id: int) {
        self.id = id
    }

    fn deinit() {
        io.println("drop {self.id}")
    }
}

interface Talker {
    fn speak()
}

class Speaker implements Talker {
    id: int = 0

    pub fn init(id: int) {
        self.id = id
    }

    pub fn speak() {}

    fn deinit() {
        io.println("drop {self.id}")
    }
}

struct Pair {
    early: Loud
    late: Loud
}

// A generic class: every field's declared type is a type parameter or an
// Option over one, so no field type spells a class name at all. The
// initializer writes them in a deliberately scrambled order.
class Erased<V> {
    one: V
    two: Option<V>
    three: V
    four: Option<V>
    five: V
    six: Option<V> = none

    pub fn init(a: V, b: V, c: V, d: V, e: V, f: V) {
        self.four = some(d)
        self.one = a
        self.six = some(f)
        self.five = e
        self.two = some(b)
        self.three = c
    }
}

// Composites over a class, mixing defaulted fields with initializer-written
// ones and writing them back to front.
class Wrapped {
    one: Option<Loud> = none
    two: Result<Loud, string>
    three: List<Loud>
    four: Map<string, Loud>
    five: Pair
    six: Option<Loud> = none

    pub fn init(a: Loud, b: Loud, c: Loud, d: Loud, e: Loud, f: Loud,
                g: Loud) {
        self.six = some(f)
        self.five = Pair { late: g, early: e }
        self.four = {"k": d}
        self.three = [c]
        self.two = ok(b)
        self.one = some(a)
    }
}

// The shape that always worked: fields whose declared type is the class or
// interface itself. Pinned so the fix does not move it.
class Named {
    one: Loud
    two: Talker
    three: Loud

    pub fn init(a: Loud, b: Talker, c: Loud) {
        self.three = c
        self.one = a
        self.two = b
    }
}

class ChainBase {
    b1: Option<Loud> = none
    b2: Option<Loud> = none
    b3: Option<Loud>

    pub fn init(a: Loud, b: Loud, c: Loud) {
        self.b3 = some(c)
        self.b1 = some(a)
        self.b2 = some(b)
    }
}

class ChainDerived extends ChainBase {
    d1: Option<Loud>
    d2: Option<Loud> = none
    d3: Option<Loud> = none

    pub fn init(a: Loud, b: Loud, c: Loud, d: Loud, e: Loud, f: Loud) {
        self.d3 = some(f)
        self.d1 = some(d)
        self.d2 = some(e)
        super.init(a, b, c)
    }
}

// An enum payload and a Box are two more composite shapes whose declared type
// never spells a class name, and each reaches the emitter by its own path.
enum Carried {
    empty
    one(item: Loud)
}

class Held {
    one: Carried = Carried.empty
    two: Box<Loud>
    three: Option<Loud> = none
    four: Carried = Carried.empty

    pub fn init(a: Loud, b: Loud, c: Loud, d: Loud) {
        self.four = Carried.one(d)
        self.three = some(c)
        self.two = new Box<Loud>(b)
        self.one = Carried.one(a)
    }
}

// One field: n=1 proves nothing on its own, but a rule that only works from
// two fields up is worth catching.
class Single {
    only: Option<Loud> = none

    pub fn init(a: Loud) {
        self.only = some(a)
    }
}

// Both slots start at their default and are filled from outside after
// construction, back to front. The defaults are what make construct-then-fill
// well-formed (issue #94: a field with no default needs an init to assign it);
// the release order is still reverse declaration.
class Late {
    first: Option<Loud> = none
    second: Option<Loud> = none

    pub fn init() {}
}

fn mark(name: string) -> int {
    io.println("default {name}")
    return 1
}

class DefaultBase {
    db1: int = mark("base 1")
    db2: int = mark("base 2")

    pub fn init() {
        io.println("base init")
    }
}

class DefaultDerived extends DefaultBase {
    dd1: int = mark("derived 1")
    dd2: int = mark("derived 2")

    pub fn init() {
        super.init()
        io.println("derived init")
    }
}

fn erased() {
    io.println("-- generic parameter fields --")
    var value: Erased<Loud> =
        new Erased<Loud>(
            new Loud(1), new Loud(2), new Loud(3),
            new Loud(4), new Loud(5), new Loud(6))
    io.println("built {value.one.id}")
}

fn wrapped() {
    io.println("-- composites over a class --")
    var value: Wrapped =
        new Wrapped(
            new Loud(11), new Loud(12), new Loud(13),
            new Loud(14), new Loud(15), new Loud(16),
            new Loud(17))
    io.println("built {value.three.len()}")
}

fn named() {
    io.println("-- class and interface fields --")
    var value: Named =
        new Named(new Loud(21), new Speaker(22), new Loud(23))
    io.println("built {value.one.id}")
}

fn inherited() {
    io.println("-- base and derived fields --")
    var value: ChainDerived =
        new ChainDerived(
            new Loud(31), new Loud(32), new Loud(33),
            new Loud(34), new Loud(35), new Loud(36))
    io.println("built {value.d1.is_some()}")
}

fn held() {
    io.println("-- enum payload and Box fields --")
    var value: Held =
        new Held(new Loud(71), new Loud(72), new Loud(73), new Loud(74))
    io.println("built {value.three.is_some()}")
}

fn single() {
    io.println("-- one field --")
    var value: Single = new Single(new Loud(41))
    io.println("built {value.only.is_some()}")
}

fn late() {
    io.println("-- written after construction --")
    var value: Late = new Late()
    value.second = some(new Loud(52))
    value.first = some(new Loud(51))
    io.println("built {value.first.is_some()}")
}

fn record_literal() {
    io.println("-- struct literal out of declaration order --")
    let value: Pair =
        Pair { late: new Loud(62), early: new Loud(61) }
    io.println("built {value.early.id}")
}

fn defaults() {
    io.println("-- default evaluation order --")
    let value: DefaultDerived = new DefaultDerived()
    io.println("sum {value.db1 + value.db2 + value.dd1 + value.dd2}")
}

fn main() {
    erased()
    wrapped()
    named()
    inherited()
    held()
    single()
    late()
    record_literal()
    defaults()
}
