// #158 — a reflective call, read and write on members a generic class
// declares. The registry files one row per OPEN declaration, so the tree
// interpreter served these off the live object while the native backend,
// having no instantiation to name in a monomorphic function pointer, handed
// the runtime null and answered `unsupported`.
//
// Two instantiations whose layouts differ (`Cell<int>` is narrower than
// `Cell<Wide>`, so `tag` sits at a different offset in each), plus a subclass
// that overrides, so an answer that is right for one layout is not enough.
// The markers are on an owned value each cell holds: eight built, eight
// released — four cells constructed, and four `Held` values replaced by a
// reflective write. A thunk that read or wrote the wrong slot would drop the
// wrong reference and the tags would stop matching.
package main

import std.io
import std.reflect

pub struct Wide { pub a: int; pub b: int; pub c: int }

pub class Held {
    pub name: string
    pub fn init(name: string) {
        self.name = name
        io.println("arc+{name}")
    }
    fn deinit() { io.println("arc-{self.name}") }
}

pub interface Bumped { pub fn touch(step: int) -> int }

pub class Cell<T> implements Bumped {
    pub item: T
    pub tag: int = 1
    pub held: Held
    pub fn init(item: T, held: Held) {
        self.item = item
        self.held = held
    }
    pub fn touch(step: int) -> int {
        self.tag = self.tag + step
        return self.tag
    }
    pub static fn stamp() -> int { return 99 }
}

pub class Doubling<T> extends Cell<T> {
    pub fn init(item: T, held: Held) { super.init(item, held) }
    pub override fn touch(step: int) -> int {
        self.tag = self.tag + step * 2
        return self.tag
    }
}

pub class Base<T> { pub mark: int = 5; pub fn init() {} }
pub class Plain extends Base<int> { pub start: int = 41 }

fn call(name: string, owner: reflect.Type, receiver: reflect.Value,
        method: string, move args: List<reflect.Value>) {
    match owner.method(method) {
        some(m) => {
            match m.call(receiver, move args) {
                ok(v) => io.println("{name}: {(v as? int).or(-1)}"),
                err(e) => io.println("{name}: {e.kind()}"),
            }
        }
        none => io.println("{name}: no such method"),
    }
}

fn main() {
    var narrow: Cell<int> = new Cell<int>(7, new Held("narrow"))
    var wide: Cell<Wide> =
        new Cell<Wide>(Wide { a: 1, b: 2, c: 3 }, new Held("wide"))
    var sub: Doubling<int> = new Doubling<int>(4, new Held("sub"))
    var other: Cell<int> = new Cell<int>(8, new Held("other"))
    let vnarrow: reflect.Value = reflect.value(narrow)
    let vwide: reflect.Value = reflect.value(wide)
    let vsub: reflect.Value = reflect.value(sub)
    let vother: reflect.Value = reflect.value(other)

    call("touch narrow", type_of(Bumped), vnarrow, "touch",
         [reflect.value(3)])
    call("touch wide", type_of(Bumped), vwide, "touch", [reflect.value(5)])
    call("touch override", type_of(Bumped), vsub, "touch",
         [reflect.value(3)])
    call("touch other", type_of(Bumped), vother, "touch",
         [reflect.value(9)])

    let tag_narrow: reflect.Field =
        type_of(Cell<int>).field("tag").expect("tag")
    let tag_wide: reflect.Field =
        type_of(Cell<Wide>).field("tag").expect("tag")
    io.println("read {(tag_narrow.get(vnarrow).expect("g") as? int).or(-1)} {(tag_wide.get(vwide).expect("g") as? int).or(-1)}")
    tag_narrow.set(vnarrow, reflect.value(30)).expect("set narrow")
    tag_wide.set(vwide, reflect.value(40)).expect("set wide")
    io.println("wrote {narrow.tag} {wide.tag} {sub.tag} {other.tag}")
    io.println("items {narrow.item} {wide.item.a},{wide.item.b},{wide.item.c}")

    // the owned slot is reachable too, and a reflective write releases the
    // reference it replaces exactly once
    let held_narrow: reflect.Field =
        type_of(Cell<int>).field("held").expect("held")
    let held_wide: reflect.Field =
        type_of(Cell<Wide>).field("held").expect("held")
    let held_sub: reflect.Field =
        type_of(Doubling<int>).field("held").expect("held")
    let held_other: reflect.Field =
        type_of(Cell<int>).field("held").expect("held")
    held_narrow.set(vnarrow, reflect.value(new Held("narrow2")))
        .expect("replace narrow")
    held_wide.set(vwide, reflect.value(new Held("wide2")))
        .expect("replace wide")
    held_sub.set(vsub, reflect.value(new Held("sub2")))
        .expect("replace sub")
    held_other.set(vother, reflect.value(new Held("other2")))
        .expect("replace other")
    io.println("held {narrow.held.name} {wide.held.name} {sub.held.name} {other.held.name}")

    // refused on both backends: no receiver names which body to run
    match type_of(Cell<int>).method("stamp") {
        some(m) => {
            match m.call_static([]) {
                ok(_) => io.println("stamp: ok"),
                err(e) => io.println("stamp: {e.kind()}"),
            }
        }
        none => io.println("stamp: no such method"),
    }

    // a plain subclass of a closed generic constructs both ways
    match type_of(Plain).initializer() {
        some(i) => {
            match i.call([]) {
                ok(v) => io.println("built {v.type().qualified_name()}"),
                err(e) => io.println("built: {e.kind()}"),
            }
        }
        none => io.println("no initializer"),
    }
    let written: Plain = new Plain()
    io.println("new Plain {written.start} {written.mark}")
}
