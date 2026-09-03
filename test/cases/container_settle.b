// A container settles before it releases what it held: the storage is
// detached and an empty container published before the first element's
// release, so a `deinit` that reads the container sees it empty, and one that
// adds to it keeps what it added (spec/CONCURRENCY.md).
//
// A map entry has two halves. The interpreter published one of them: it stored
// a fresh key list, which released every class key, while the value map -- the
// field `len`, `is_empty` and `contains_key` all read -- was still full
// (issue #83). Emptying the other one first only moves the hole: `keys()` would
// then answer the old keys while `len()` answered 0. Both halves have to be set
// aside before either store runs.
//
// The back-reference each element holds is `weak` on purpose: a strong one
// makes element and container a cycle, and a cycle's teardown is the collector's
// business, not this file's.
import std.io

class Holder {
    plain: Map<Element, int> = {}
    ordered: OrderedMap<Element, int> = {}
    valued: Map<int, Element> = {}
    both: Map<Element, Element> = {}
    items: List<Element> = []
    slab: Arena<Element> = new Arena<Element>(8)
    nested: List<Map<Element, int>> = []
    refill: bool = false

    pub fn init() {}

    fn report(who: string) {
        io.println("{who}: plain={self.plain.len()}/{self.plain.keys().len()} ordered={self.ordered.len()}/{self.ordered.keys().len()} valued={self.valued.len()} both={self.both.len()}/{self.both.keys().len()} items={self.items.len()} slab={self.slab.len()}")
    }
}

class Element {
    label: string = ""
    weak owner: Option<Holder> = none

    pub fn init(label: string, owner: Holder) {
        self.label = label
        self.owner = some(owner)
    }

    fn deinit() {
        match self.owner {
            some(holder) => {
                holder.report(self.label)
                // One element puts something back while the clear is still
                // running. What it adds belongs to the cleared container.
                if holder.refill && self.label == "refill-a1" {
                    holder.plain[new Element("planted", holder)] = 99
                }
            }
            none => {
                io.println("{self.label}: owner gone")
            }
        }
    }
}

fn fill(holder: Holder, count: int, tag: string) {
    var index: int = 0
    for index < count {
        holder.plain[new Element("{tag}-p{index}", holder)] = index
        holder.ordered[new Element("{tag}-o{index}", holder)] = index
        holder.valued[index] = new Element("{tag}-v{index}", holder)
        holder.both[new Element("{tag}-bk{index}", holder)] =
            new Element("{tag}-bv{index}", holder)
        holder.items.push(new Element("{tag}-l{index}", holder))
        holder.slab.add(new Element("{tag}-a{index}", holder))
        index += 1
    }
}

fn clear_all(holder: Holder, tag: string) {
    io.println("[{tag}] clear plain")
    holder.plain.clear()
    io.println("[{tag}] clear ordered")
    holder.ordered.clear()
    io.println("[{tag}] clear valued")
    holder.valued.clear()
    io.println("[{tag}] clear both")
    holder.both.clear()
    io.println("[{tag}] clear items")
    holder.items.clear()
    io.println("[{tag}] clear slab")
    holder.slab.clear()
    io.println("[{tag}] cleared")
}

// n = 1: one entry cannot tell a settled container from an unsettled one by
// counting, but it can by reading -- and it is the size the earlier bugs in
// this area hid behind.
fn one() {
    let holder: Holder = new Holder()
    fill(holder, 1, "one")
    clear_all(holder, "one")
}

fn two() {
    let holder: Holder = new Holder()
    fill(holder, 2, "two")
    clear_all(holder, "two")
}

// Past a Map's first reallocation, so the entry buffer has grown and the
// index has been rebuilt at least once.
fn many() {
    let holder: Holder = new Holder()
    fill(holder, 6, "many")
    clear_all(holder, "many")
}

// A removal takes the entry out first: len, contains_key and keys() all see it
// gone before the value's deinit runs.
fn removal() {
    let holder: Holder = new Holder()
    fill(holder, 3, "rm")
    io.println("[rm] removing valued 1")
    holder.valued.remove(1)
    io.println("[rm] removed, valued={holder.valued.len()}")
    clear_all(holder, "rm")
}

// Reassignment publishes the new container before the old one is released.
fn reassignment() {
    let holder: Holder = new Holder()
    fill(holder, 2, "re")
    io.println("[re] reassigning plain")
    holder.plain = {}
    io.println("[re] reassigned, plain={holder.plain.len()}")
    clear_all(holder, "re")
}

// A container inside a container: clearing the outer one releases the inner
// maps, and each inner clear settles on its own.
fn nested() {
    let holder: Holder = new Holder()
    var index: int = 0
    for index < 2 {
        var inner: Map<Element, int> = {}
        inner[new Element("nest-{index}a", holder)] = index
        inner[new Element("nest-{index}b", holder)] = index
        holder.nested.push(move inner)
        index += 1
    }
    io.println("[nested] clearing outer, nested={holder.nested.len()}")
    holder.nested.clear()
    io.println("[nested] cleared, nested={holder.nested.len()}")
}

// A deinit that adds to the container it is being cleared out of keeps what it
// added, and the container is usable afterwards.
fn puts_back() {
    let holder: Holder = new Holder()
    holder.refill = true
    holder.plain[new Element("refill-a1", holder)] = 1
    holder.plain[new Element("refill-a2", holder)] = 2
    io.println("[refill] clearing, plain={holder.plain.len()}")
    holder.plain.clear()
    io.println("[refill] cleared, plain={holder.plain.len()}")
    holder.refill = false
    holder.plain[new Element("refill-b1", holder)] = 3
    io.println("[refill] reusable, plain={holder.plain.len()}")
    holder.plain.clear()
    io.println("[refill] done, plain={holder.plain.len()}")
}

fn main() {
    one()
    two()
    many()
    removal()
    reassignment()
    nested()
    puts_back()
}
