// a consumed constructor operand's reference dies with the init
// call: the initializer borrows and retains what it stores, so
// the caller must release its own count right after. Skipping
// that release leaked every owned argument — a Tracer passed
// into new Holder<T> never saw its deinit. Immortal string
// literals hid the same hole in every earlier test. A borrowed
// call site (the argument is used again afterwards) must keep
// its count and stay alive.
import std.io

class Tracer {
    name: string

    fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("drop {self.name}")
    }
}

class Wrap {
    inner: Tracer

    fn init(inner: Tracer) {
        self.inner = inner
    }

    fn deinit() {
        io.println("wrap down")
    }
}

class Holder<T> {
    inner: T

    fn init(inner: T) {
        self.inner = inner
    }
}

fn consumed_generic() {
    let kept: Holder<Tracer> = new Holder<Tracer>(new Tracer("generic"))
    io.println("generic made")
}

fn consumed_plain() {
    let kept: Wrap = new Wrap(new Tracer("plain"))
    io.println("plain made")
}

fn borrowed_site() {
    let shared: Tracer = new Tracer("shared")
    let kept: Holder<Tracer> = new Holder<Tracer>(shared)
    io.println("still {shared.name}")
}

// a declared move parameter takes the caller's count with it: the
// caller must NOT release after the call. Releasing anyway freed
// stage 2's token list out from under the parser.
class Vault {
    items: List<Tracer>

    fn init(move items: List<Tracer>) {
        self.items = move items
    }

    fn deinit() {
        io.println("vault of {self.items.len()} closed")
    }
}

fn moved_site() {
    var goods: List<Tracer> = []
    goods.push(new Tracer("cargo"))
    let vault: Vault = new Vault(move goods)
    io.println("stored {vault.items.len()}")
}

fn main() {
    consumed_generic()
    consumed_plain()
    borrowed_site()
    moved_site()
    io.println("end")
}
