// A `deinit` that panics does not stop the destruction that was running it
// (issue #81, spec/CONCURRENCY.md).
//
// Contained by brew/join, the panic unwinds out of the runtime frame that was
// tearing something down. The native backend used to stop there: the elements
// a `clear` had not reached yet were never destroyed and never freed, and the
// container already reported itself empty, so nothing in the program could
// reach them either — O(n) lost per caught panic. The tree interpreter, whose
// panic is a poison flag rather than a stack unwind, destroyed all of them.
// One checked program, two answers, and a leak on the native side.
//
// The rule both backends now keep: the release finishes. The object whose
// deinit panicked does not run its deinit twice, but its fields go and its
// memory comes back, and everything else the release still owed is destroyed
// in the order it would have been destroyed in anyway.
//
// Every section counts as well as prints, and every count is above two: a
// container of one element, or two, cannot tell "stopped at the panic" from
// "finished".
import std.io

class Tally {
    pub static gone: int = 0
    pub static fn reset() { Tally.gone = 0 }
}

class Item {
    pub id: int = 0
    pub bomb: bool = false
    pub fn init(id: int, bomb: bool) {
        self.id = id
        self.bomb = bomb
    }
    fn deinit() {
        Tally.gone += 1
        io.println("  drop {self.id}")
        if self.bomb { panic("deinit bomb {self.id}") }
    }
}

// A leaf with no deinit of its own would prove nothing about field release,
// so every child prints too.
class Leaf {
    pub id: int = 0
    pub fn init(id: int) { self.id = id }
    fn deinit() {
        Tally.gone += 1
        io.println("  drop leaf {self.id}")
    }
}

// The object whose own deinit panics: its fields must still be released.
class Owner {
    pub id: int = 0
    pub one: Leaf
    pub two: Leaf
    pub fn init(id: int) {
        self.id = id
        self.one = new Leaf(id * 10)
        self.two = new Leaf(id * 10 + 1)
    }
    fn deinit() {
        Tally.gone += 1
        io.println("  drop owner {self.id}")
        if self.id == 1 { panic("deinit bomb owner") }
    }
}

class Link {
    pub id: int = 0
    pub bomb: bool = false
    pub next: Option<Link> = none
    pub fn init(id: int, bomb: bool) {
        self.id = id
        self.bomb = bomb
    }
    fn deinit() {
        Tally.gone += 1
        io.println("  drop link {self.id}")
        if self.bomb { panic("deinit bomb link {self.id}") }
    }
}

struct Trio {
    pub a: Item
    pub b: Item
    pub c: Item
}

fn twelve() -> List<Item> {
    var l: List<Item> = []
    var i: int = 0
    for i < 12 {
        l.push(new Item(i, i == 7))
        i += 1
    }
    return move l
}

fn report(label: string, outcome: string, count: int) {
    io.println("{label}: {outcome}, {count} destroyed")
}

fn wipe_list(l: List<Item>) -> int { l.clear(); return 0 }
fn wipe_map(m: Map<int, Item>) -> int { m.clear(); return 0 }
fn wipe_ordered(m: OrderedMap<int, Item>) -> int { m.clear(); return 0 }
fn wipe_arena(a: Arena<Item>) -> int { a.clear(); return 0 }

// A container that dies at scope exit rather than through `clear`: the
// cascade's own work stack is what holds the rest of the elements there.
fn scope_list() -> int {
    let held: List<Item> = twelve()
    return held.len()
}

// A plain object graph, no container in sight: twelve links, each owning the
// next, dropped by letting the head go.
fn chain() -> int {
    var head: Option<Link> = none
    var i: int = 0
    for i < 12 {
        let node: Link = new Link(i, i == 4)
        node.next = head
        head = some(node)
        i += 1
    }
    return i
}

fn nested(outer: List<List<Item>>) -> int { outer.clear(); return 0 }

fn wipe_wide(l: List<Trio>) -> int { l.clear(); return 0 }

fn drop_owner() -> int {
    let outer: Leaf = new Leaf(99)
    let boom: Owner = new Owner(1)
    return 0
}

fn swap_box(b: Box<Owner>) -> int { b.set(new Owner(2)); return 0 }
fn swap_wide_box(b: Box<Trio>) -> int {
    b.set(Trio { a: new Item(20, false), b: new Item(21, false),
                 c: new Item(22, false) })
    return 0
}

fn remove_wide(m: Map<int, Trio>) -> int { m.remove(1); return 0 }

fn outcome(problem: string) -> string { return problem }

fn main() {
    // 1. clear() on each container the runtime tears down itself.
    var l: List<Item> = twelve()
    Tally.reset()
    let a: Brew<int> = brew wipe_list(l)
    match a.join() {
        ok(v) => { report("list clear", "ok", Tally.gone) }
        err(p) => { report("list clear", p.kind, Tally.gone) }
    }
    io.println("list len={l.len()}")

    var m: Map<int, Item> = {}
    var i: int = 0
    for i < 12 { m[i] = new Item(i, i == 7); i += 1 }
    Tally.reset()
    let b: Brew<int> = brew wipe_map(m)
    match b.join() {
        ok(v) => { report("map clear", "ok", Tally.gone) }
        err(p) => { report("map clear", p.kind, Tally.gone) }
    }
    io.println("map len={m.len()}")

    var om: OrderedMap<int, Item> = {}
    i = 0
    for i < 12 { om[i] = new Item(i, i == 7); i += 1 }
    Tally.reset()
    let c: Brew<int> = brew wipe_ordered(om)
    match c.join() {
        ok(v) => { report("ordered clear", "ok", Tally.gone) }
        err(p) => { report("ordered clear", p.kind, Tally.gone) }
    }
    io.println("ordered len={om.len()}")

    var ar: Arena<Item> = new Arena(16)
    i = 0
    for i < 12 { ar.add(new Item(i, i == 7)); i += 1 }
    Tally.reset()
    let d: Brew<int> = brew wipe_arena(ar)
    match d.join() {
        ok(v) => { report("arena clear", "ok", Tally.gone) }
        err(p) => { report("arena clear", p.kind, Tally.gone) }
    }
    io.println("arena len={ar.len()}")

    // 2. A container dying at scope exit, and a graph with no container.
    Tally.reset()
    let e: Brew<int> = brew scope_list()
    match e.join() {
        ok(v) => { report("list scope", "ok", Tally.gone) }
        err(p) => { report("list scope", p.kind, Tally.gone) }
    }

    Tally.reset()
    let f: Brew<int> = brew chain()
    match f.join() {
        ok(v) => { report("graph", "ok", Tally.gone) }
        err(p) => { report("graph", p.kind, Tally.gone) }
    }

    // 3. Nested containers: the inner list's panic must not cost the outer
    // list the two inner lists it had not reached.
    var outer: List<List<Item>> = []
    i = 0
    for i < 3 {
        var inner: List<Item> = []
        var j: int = 0
        for j < 3 {
            inner.push(new Item(i * 10 + j, i == 2 && j == 1))
            j += 1
        }
        outer.push(move inner)
        i += 1
    }
    Tally.reset()
    let g: Brew<int> = brew nested(outer)
    match g.join() {
        ok(v) => { report("nested", "ok", Tally.gone) }
        err(p) => { report("nested", p.kind, Tally.gone) }
    }
    io.println("nested len={outer.len()}")

    // 4. A wide element: last field first, and the fields before the
    // panicking one still go.
    var wide: List<Trio> = []
    wide.push(Trio { a: new Item(1, false), b: new Item(2, false),
                     c: new Item(3, false) })
    wide.push(Trio { a: new Item(4, false), b: new Item(5, true),
                     c: new Item(6, false) })
    wide.push(Trio { a: new Item(7, false), b: new Item(8, false),
                     c: new Item(9, false) })
    Tally.reset()
    let h: Brew<int> = brew wipe_wide(wide)
    match h.join() {
        ok(v) => { report("wide clear", "ok", Tally.gone) }
        err(p) => { report("wide clear", p.kind, Tally.gone) }
    }
    io.println("wide len={wide.len()}")

    // 5. The panicking object's own fields.
    Tally.reset()
    let k: Brew<int> = brew drop_owner()
    match k.join() {
        ok(v) => { report("owner fields", "ok", Tally.gone) }
        err(p) => { report("owner fields", p.kind, Tally.gone) }
    }

    // 6. Box.set, narrow and wide: the store stands and the old value goes.
    let nb: Box<Owner> = new Box(new Owner(1))
    Tally.reset()
    let n: Brew<int> = brew swap_box(nb)
    match n.join() {
        ok(v) => { report("box set", "ok", Tally.gone) }
        err(p) => { report("box set", p.kind, Tally.gone) }
    }
    io.println("box holds={nb.get().id}")

    let wb: Box<Trio> = new Box(Trio { a: new Item(10, false),
                                       b: new Item(11, true),
                                       c: new Item(12, false) })
    Tally.reset()
    let o: Brew<int> = brew swap_wide_box(wb)
    match o.join() {
        ok(v) => { report("wide box set", "ok", Tally.gone) }
        err(p) => { report("wide box set", p.kind, Tally.gone) }
    }
    io.println("wide box holds={wb.get().a.id},{wb.get().b.id},{wb.get().c.id}")

    // 7. remove() of a wide entry.
    var wm: Map<int, Trio> = {}
    wm[1] = Trio { a: new Item(30, false), b: new Item(31, false),
                   c: new Item(32, true) }
    wm[2] = Trio { a: new Item(33, false), b: new Item(34, false),
                   c: new Item(35, false) }
    Tally.reset()
    let q: Brew<int> = brew remove_wide(wm)
    match q.join() {
        ok(v) => { report("wide remove", "ok", Tally.gone) }
        err(p) => { report("wide remove", p.kind, Tally.gone) }
    }
    io.println("wide map len={wm.len()}")

    // 8. Every container is still usable afterwards.
    l.push(new Item(100, false))
    m[100] = new Item(101, false)
    om[100] = new Item(102, false)
    ar.add(new Item(103, false))
    io.println("reused list={l.len()} map={m.len()} ordered={om.len()} arena={ar.len()}")
    io.println("end")
}
