// Every map entry point the emitter can put inside a loop, exercised past the
// linear-scan cutoff (MAP_LINEAR_MAX is 8, so these sizes run the hash index,
// its tombstones and its reindex) and with removals, so an OrderedMap has real
// holes for iteration to skip.
//
// test/map_inline.sh builds this twice: without --lto every one of those entry
// points must be a symbol in the binary, which is what proves the program
// really reaches them, and with --lto not one of them may survive, which is
// what proves always_inline folded them all. The answers below must match on
// the interpreter and on both builds.
import std.io

struct Point {
    x: int
    y: int
}

class Tag {
    pub name: string
    fn init(name: string) { self.name = name }
    fn deinit() { io.println("drop {self.name}") }
}

// Every Cell counts itself in and out. A removal that released a value twice,
// or dropped an entry without releasing it, shows up as a non-zero balance —
// a claim that does not depend on the order the drops happen in, so it holds
// across a randomised stream where a golden could not.
class Tally {
    pub live: int = 0
    pub made: int = 0
    pub fn up() {
        self.live += 1
        self.made += 1
    }
    pub fn down() { self.live -= 1 }
}

class Cell {
    pub key: int
    pub tally: Tally
    fn init(key: int, tally: Tally) {
        self.key = key
        self.tally = tally
        tally.up()
    }
    fn deinit() { self.tally.down() }
}

fn find(keys: List<int>, key: int) -> int {
    var index: int = 0
    for index < keys.len() {
        if keys.get(index).or(-1) == key { return index }
        index += 1
    }
    return -1
}

fn main() {
    let n: int = 40

    // slot key, slot value: set_raw, get_raw_out, contains_raw, insert_raw,
    // remove_raw, add_raw, and the four plain iterator entry points
    var plain: Map<int, int> = {}
    var i: int = 0
    for i < n {
        plain[i * 3] = i
        i += 1
    }
    var fresh: int = 0
    i = 0
    for i < n {
        if plain.insert(i * 3 + 1, i) { fresh += 1 }
        i += 1
    }
    var found: int = 0
    var present: int = 0
    i = 0
    for i < n * 3 {
        match plain.get(i) {
            some(value) => { found += value + 1 }
            none => {}
        }
        if plain.contains_key(i) { present += 1 }
        i += 1
    }
    var dropped: int = 0
    i = 0
    for i < n {
        if i % 3 == 0 && plain.remove(i * 3) { dropped += 1 }
        i += 1
    }
    var walked: int = 0
    var pairs: int = 0
    for key: int, value: int in plain {
        walked += key ^ value
        pairs += 1
    }
    io.println("plain {fresh} {found} {present} {dropped} {pairs} {walked} {plain.len()}")

    // slot key, wide value: set_typed_raw, get_typed_raw, insert_typed_raw,
    // and iter_value_typed
    var wide: Map<int, Point> = {}
    i = 0
    for i < n {
        wide[i] = Point { x: i, y: i * 2 }
        i += 1
    }
    var refused: int = 0
    i = 0
    for i < n {
        if !wide.insert(i, Point { x: 0, y: 0 }) { refused += 1 }
        i += 1
    }
    var read: int = 0
    i = 0
    for i < n {
        match wide.get(i) {
            some(point) => { read += point.x + point.y }
            none => {}
        }
        i += 1
    }
    i = 0
    for i < n {
        if i % 4 == 0 { wide.remove(i) }
        i += 1
    }
    var wide_walk: int = 0
    for key: int, value: Point in wide {
        wide_walk += key + value.x + value.y
    }
    io.println("wide {refused} {read} {wide_walk} {wide.len()}")

    // wide key: iter_key_typed
    var keyed: Map<Point, int> = {}
    i = 0
    for i < n {
        keyed[Point { x: i, y: n - i }] = i
        i += 1
    }
    var keyed_walk: int = 0
    for key: Point, value: int in keyed {
        keyed_walk += key.x * 2 + key.y + value
    }
    io.println("keyed {keyed_walk} {keyed.len()}")

    // OrderedMap: removal leaves stable holes, so iter_next has to skip dead
    // slots rather than walk a dense array
    var ordered: OrderedMap<int, int> = {}
    i = 0
    for i < n {
        ordered[i] = i * i
        i += 1
    }
    i = 0
    for i < n {
        if i % 2 == 1 { ordered.remove(i) }
        i += 1
    }
    var order: int = 0
    var seen: int = 0
    for key: int, value: int in ordered {
        order = order * 31 + key
        seen += value
        order = order % 1_000_003
    }
    io.println("ordered {order} {seen} {ordered.len()}")

    // reference values, so the release inside remove runs user code and the
    // map's own teardown runs the rest
    var owned: Map<int, Tag> = {}
    i = 0
    for i < 12 {
        owned[i] = new Tag("t{i}")
        i += 1
    }
    owned.remove(5)
    owned.remove(0)
    io.println("owned {owned.len()}")

    // Five thousand set/remove/insert steps against a linear model, with a
    // reference value per entry. The map has to agree with the model on every
    // key, and every Cell made has to be released exactly once.
    let tally: Tally = new Tally()
    var cells: Map<int, Cell> = {}
    var model: List<int> = []
    var seed: u64 = 0x9e3779b97f4a7c15
    var errors: int = 0
    var step: int = 0
    for step < 5000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        let key: int = (seed % 193) as int
        let at: int = find(model, key)
        let operation: int = step % 5
        if operation < 2 {
            cells[key] = new Cell(key, tally)
            if at < 0 { model.push(key) }
        } else if operation == 2 {
            let added: bool = cells.insert(key, new Cell(key, tally))
            if added != (at < 0) { errors += 1 }
            if at < 0 { model.push(key) }
        } else if operation == 3 {
            let gone: bool = cells.remove(key)
            if gone != (at >= 0) { errors += 1 }
            if at >= 0 { model.remove(at) }
        } else {
            if cells.contains_key(key) != (at >= 0) { errors += 1 }
            match cells.get(key) {
                some(cell) => { if cell.key != key { errors += 1 } }
                none => { if at >= 0 { errors += 1 } }
            }
        }
        step += 1
    }
    if cells.len() != model.len() { errors += 1 }
    var index: int = 0
    for index < model.len() {
        if !cells.contains_key(model.get(index).or(-1)) { errors += 1 }
        index += 1
    }
    if tally.live != cells.len() { errors += 1 }
    io.println("model {errors} {cells.len()} {tally.made} {tally.live}")
    cells.clear()
    io.println("cleared {tally.live}")
}
