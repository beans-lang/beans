// What a container looks like after a contained panic in one of its elements'
// deinits (issue #79, spec/CONCURRENCY.md).
//
// `clear` and `Box.set` release what the container owns, and for a class value
// that runs user code. Contained by brew/join a panic there unwinds out of the
// runtime frame, so the container has to be showing the program the state it
// will have afterwards before the first release runs. The native runtime
// released first and updated the container after, so it was left reporting
// every element it had just destroyed — `len` unchanged, `contains_key` true,
// and `Box.get` handing back the value the box had just dropped instead of the
// one it was given. The interpreter, which replaces the storage outright
// (`items = []`, `map_values = {}`), reported them empty. One checked program,
// two answers.
//
// Twelve elements, so a Map runs its hash index rather than the linear scan,
// and each container is used again afterwards: an emptied container is not
// merely reported empty, it works.
import std.io

class Loud {
    pub name: string
    pub loud: bool
    fn init(name: string, loud: bool) {
        self.name = name
        self.loud = loud
    }
    fn deinit() {
        if self.loud {
            io.println("  deinit {self.name} panics")
            let empty: List<int> = []
            let unused: int = empty[0]
        }
    }
}

class ListHolder {
    pub items: List<Loud> = []
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items.push(new Loud("l{i}", i == 5))
            i += 1
        }
    }
    pub fn wipe() -> int {
        self.items.clear()
        return 0
    }
}

class MapHolder {
    pub items: Map<int, Loud> = {}
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items[i] = new Loud("m{i}", i == 5)
            i += 1
        }
    }
    pub fn wipe() -> int {
        self.items.clear()
        return 0
    }
}

class OrderedHolder {
    pub items: OrderedMap<int, Loud> = {}
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items[i] = new Loud("o{i}", i == 5)
            i += 1
        }
    }
    pub fn wipe() -> int {
        self.items.clear()
        return 0
    }
}

class ArenaHolder {
    pub items: Arena<Loud> = new Arena(16)
    pub fn fill(n: int) {
        var i: int = 0
        for i < n {
            self.items.add(new Loud("a{i}", i == 5))
            i += 1
        }
    }
    pub fn wipe() -> int {
        self.items.clear()
        return 0
    }
}

class BoxHolder {
    pub cell: Box<Loud> = new Box(new Loud("old", true))
    pub fn swap(name: string) -> int {
        self.cell.set(new Loud(name, false))
        return 0
    }
}

fn report(label: string, problem: string) {
    io.println("{label} {problem}")
}

fn main() {
    let list: ListHolder = new ListHolder()
    list.fill(12)
    let a: Brew<int> = brew list.wipe()
    match a.join() {
        ok(v) => { report("list", "cleared") }
        err(problem) => { report("list", problem.kind) }
    }
    list.items.push(new Loud("after", false))
    io.println("list len={list.items.len()} first={list.items[0].name}")

    let plain: MapHolder = new MapHolder()
    plain.fill(12)
    let b: Brew<int> = brew plain.wipe()
    match b.join() {
        ok(v) => { report("map", "cleared") }
        err(problem) => { report("map", problem.kind) }
    }
    plain.items[7] = new Loud("after", false)
    io.println("map len={plain.items.len()} has9={plain.items.contains_key(9)} has7={plain.items.contains_key(7)}")

    let ordered: OrderedHolder = new OrderedHolder()
    ordered.fill(12)
    let c: Brew<int> = brew ordered.wipe()
    match c.join() {
        ok(v) => { report("ordered", "cleared") }
        err(problem) => { report("ordered", problem.kind) }
    }
    ordered.items[3] = new Loud("after", false)
    var keys: string = ""
    for key: int, value: Loud in ordered.items {
        keys = "{keys}{key}:{value.name};"
    }
    io.println("ordered len={ordered.items.len()} {keys}")

    let arena: ArenaHolder = new ArenaHolder()
    arena.fill(12)
    let d: Brew<int> = brew arena.wipe()
    match d.join() {
        ok(v) => { report("arena", "cleared") }
        err(problem) => { report("arena", problem.kind) }
    }
    let handle: int = arena.items.add(new Loud("after", false))
    io.println("arena len={arena.items.len()} handle={handle}")

    // The store stands: the box takes the value it was given even though the
    // value it dropped panicked on the way out.
    let box: BoxHolder = new BoxHolder()
    let e: Brew<int> = brew box.swap("new")
    match e.join() {
        ok(v) => { report("box", "set") }
        err(problem) => { report("box", problem.kind) }
    }
    io.println("box holds={box.cell.get().name}")
    box.swap("newer")
    io.println("box holds={box.cell.get().name}")
}
