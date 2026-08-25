// The bindings a generic interface pins are still checked. Each error
// below is locked by test/generic_interfaces.sh.
import std.io

pub interface Producer<T> {
    fn make() -> T
}

// the method answers the wrong concrete type
pub class Wrong implements Producer<int> {
    pub fn init() {}
    pub fn make() -> string { return "no" }
}

pub class IntBox implements Producer<int> {
    pub fn init() {}
    pub fn make() -> int { return 7 }
}

pub class BoxOf<T> implements Producer<T> {
    pub value: T
    pub fn init(value: T) { self.value = value }
    pub fn make() -> T { return self.value }
}

// a bound pins the interface's argument just as an implements site does
pub fn through_bound<P implements Producer<int>>(p: P) -> int {
    return p.make()
}

fn main() {
    // a pinned interface is not the same type at another argument
    let a: Producer<string> = new IntBox()
    let b: Producer<string> = new BoxOf<int>(1)
    io.println("{a.make()} {b.make()}")
    // the bound wants Producer<int>; this one produces strings
    let c: BoxOf<string> = new BoxOf<string>("no")
    io.println("{through_bound<BoxOf<string>>(c)}")
}
