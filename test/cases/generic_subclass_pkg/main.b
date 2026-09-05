// #123: a generic class extending a generic base in another package. The
// override lives on a generic class, so the record of which slots a name
// declares had no entry for it (a template carries no symbol), and matching
// the class against a `Base<int>` receiver by its written arguments — which
// say `Base<T>` — answered no. Both made the emitter believe nothing could
// replace the base body, and it compiled the call direct while the
// interpreter dispatched to the override.
package main
import std.io
import app.lib

class Sub<T> extends lib.Base<T> {
    extra: int
    fn init(v: T, extra: int) {
        self.extra = extra
        super.init(v)
    }
    override fn weight() -> int { return 2 }
}

// a non-generic leaf below the generic subclass: the other conformer shape
class Deep extends Sub<int> {
    fn init() { super.init(9, 8) }
}

// a generic subclass of a plain class in the other package
class OverPlain<T> extends lib.Plain {
    held: T
    fn init(held: T) {
        self.held = held
        super.init()
    }
}

fn main() {
    let a: Sub<int> = new Sub<int>(1, 2)
    let b: Sub<string> = new Sub<string>("s", 3)
    let d: Deep = new Deep()
    let p: lib.Base<int> = new lib.Base<int>(4)
    let o: OverPlain<int> = new OverPlain<int>(5)
    io.println("{a.v} {a.extra} {b.v} {b.extra} {d.v} {d.extra}")
    io.println("weigh {lib.weigh(a)} {lib.weigh(d)} {lib.weigh(p)}")
    io.println("secret {lib.confide(a)} {lib.confide(d)} {lib.confide(p)}")
    io.println("kind {a.kind()} {d.kind()} {o.kind()} {o.held}")
}
