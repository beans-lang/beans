// The shapes a Mutex cannot make safe, and the reason for each. An ordinary
// class is an aliasable handle: the move into the Mutex takes nothing away
// from whoever else already holds it. A unique class is the mutex's own, but
// only down to the first field something else can reach.
import std.io
import std.thread

class Plain {
    pub rows: Map<string, int> = {}
}

class Aliasable {
    pub n: int = 0
}

unique class Leaky {
    pub inner: Aliasable
    fn init(inner: Aliasable) { self.inner = inner }
}

unique class Deep {
    pub nested: Leaky
    fn init(inner: Aliasable) {
        self.nested = new Leaky(inner)
    }
}

fn ordinary_class() {
    let guard: Mutex<Plain> = new Mutex<Plain>(new Plain())
    let worker: Thread<bool> = thread.spawn(fn() -> bool {
        guard.with_lock(fn(held: Plain) { held.rows.set("hit", 1) })
        return true
    })
    let done: bool = worker.join()
    io.println("{done}")
}

fn aliasable_field() {
    let escape: Aliasable = new Aliasable()
    let guard: Mutex<Leaky> = new Mutex<Leaky>(new Leaky(escape))
    let worker: Thread<bool> = thread.spawn(fn() -> bool {
        guard.with_lock(fn(held: Leaky) { held.inner.n = 1 })
        return true
    })
    let done: bool = worker.join()
    io.println("{escape.n}")
}

fn aliasable_field_deeper() {
    let escape: Aliasable = new Aliasable()
    let guard: Mutex<Deep> =
        new Mutex<Deep>(new Deep(escape))
    let worker: Thread<bool> = thread.spawn(fn() -> bool {
        guard.with_lock(fn(held: Deep) { held.nested.inner.n = 1 })
        return true
    })
    let done: bool = worker.join()
    io.println("{escape.n}")
}

fn main() {
    ordinary_class()
    aliasable_field()
    aliasable_field_deeper()
}
