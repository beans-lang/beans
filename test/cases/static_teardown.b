// Static fields and singletons live for the whole process, and nothing tears
// them down (spec/SYNTAX.md, issue #74). The interpreter used to reach them
// through its own reference counting as the walker was released and run
// their deinit bodies, so a program with a static that owns a value with a
// deinit printed different bytes on the two backends.
//
// The rule is about the exit, not about deinit: a local still dies at the end
// of its scope, a value taken out of a static container dies right then, and
// a static that is overwritten releases what it held at the assignment. All
// three are here beside the values that survive to the end, or a fix that
// simply stopped running deinits would pass.
import std.io

class Loud {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  deinit {self.tag}") }
}

// A static that owns a value which owns another: the whole graph has to stay
// standing, not only its root.
class Holder {
    pub inner: Loud
    fn init(tag: string) { self.inner = new Loud("{tag}-inner") }
    fn deinit() { io.println("  deinit holder {self.inner.tag}") }
}

class Store {
    pub static direct: Loud = new Loud("direct")
    pub static nested: Holder = new Holder("nested")
    pub static items: List<Loud> = []
    pub static cache: Map<string, Loud> = {}
    pub static swapped: Loud = new Loud("swapped-first")
}

// The boundary the fix has to keep: a value a static still roots at exit is
// left standing, but interpreted garbage is not. A reference cycle never
// reaches zero on its own, so the collector is what ends it, and it runs each
// member's deinit on the way — at exit for a cycle nobody rooted, never for
// one a static holds. Which member the collector reaches first is its own
// discovery order and differs between the backends, so these lines carry no
// name (the same reason examples/ctors.b leaves its ring anonymous).
class Ring {
    pub next: Option<Ring> = none
    fn deinit() { io.println("  ring down") }
}

class Rooted {
    pub static held: Option<Ring> = none
}

singleton class App {
    pub held: Loud = new Loud("singleton-held")
    pub bag: List<Loud> = []
}

fn scoped_local() {
    let here: Loud = new Loud("scoped-local")
    io.println("in scope: {here.tag}")
}

// A value the static owns, borrowed through a local: the local going away is
// not the value's death, and neither is the end of the program.
fn borrow_from_static() {
    let borrowed: Loud = Store.direct
    io.println("borrowed: {borrowed.tag}")
}

// two members, no owner: the collector reclaims them at exit and both
// deinits run
fn make_garbage_cycle() {
    var a: Ring = new Ring()
    var b: Ring = new Ring()
    a.next = some(b)
    b.next = some(a)
}

// the same shape with a static holding one end: reachable, so it is not
// garbage, and nothing runs
fn make_rooted_cycle() {
    var x: Ring = new Ring()
    var y: Ring = new Ring()
    x.next = some(y)
    y.next = some(x)
    Rooted.held = some(x)
}

fn main() {
    Store.items.push(new Loud("item-0"))
    Store.items.push(new Loud("item-1"))
    Store.items.push(new Loud("item-2"))
    Store.cache["a"] = new Loud("map-a")
    Store.cache["b"] = new Loud("map-b")
    Store.cache["c"] = new Loud("map-c")
    App.instance.bag.push(new Loud("bag-0"))
    App.instance.bag.push(new Loud("bag-1"))

    scoped_local()
    borrow_from_static()

    io.println("removing item-1")
    let taken: Loud = Store.items.remove(1)
    io.println("took {taken.tag}, list holds {Store.items.len()}")

    io.println("dropping map-a")
    io.println("removed: {Store.cache.remove("a")}")

    io.println("overwriting the swapped static")
    Store.swapped = new Loud("swapped-second")

    io.println("clearing the singleton bag")
    App.instance.bag.clear()

    make_garbage_cycle()
    make_rooted_cycle()

    io.println("end: {Store.items.len()} items, {Store.cache.len()} entries, {Store.swapped.tag}")
}
