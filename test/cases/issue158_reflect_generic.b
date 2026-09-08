// #158 — reflection over members a generic class declares.
//
// The registry is erased over type arguments on both backends: one row per
// open declaration, so `type_of(Grid<int>)` and `type_of(Grid<string>)` reach
// the same row. The tree interpreter served a call off the live object; the
// native backend had to hand the runtime a monomorphic function pointer, had
// no instantiation to name, and passed null — so the same checked program
// answered on one backend and said `unsupported` on the other.
//
// This is the golden half: it pins WHAT is answered and WHAT is refused,
// which the backend-to-backend parity gate cannot, because a change that
// moves both legs together passes that gate. Every reachable shape is
// exercised at TWO instantiations whose field offsets differ, so an answer
// that happened to be right for one layout is not enough.
package main

import std.io
import std.reflect

pub struct Wide { pub a: int; pub b: int; pub c: int }

// A non-generic interface a generic class implements. The receiver check
// passes through it today, so this reaches the thunk without depending on
// any other change.
pub interface Bumped {
    pub fn touch(step: int) -> int
    pub fn note(text: string)
}

// `item` is `T`: its row says `T` and no value carries that as its type, so
// it is undescribable and both backends refuse it. `tag` and `trail` reach no
// type parameter, but they sit at DIFFERENT offsets in `Cell<int>` and
// `Cell<Wide>`, because the slot before them is as wide as the argument.
pub class Cell<T> implements Bumped {
    pub item: T
    pub tag: int = 1
    pub trail: string = "-"
    pub fn init(item: T) { self.item = item }
    pub fn touch(step: int) -> int { self.tag = self.tag + step; return self.tag }
    pub fn note(text: string) { self.trail = "{self.trail}{text}" }
    pub static fn stamp() -> int { return 99 }
    pub fn widen(other: T) -> T { return other }
}

pub class Doubling<T> extends Cell<T> {
    pub fn init(item: T) { super.init(item) }
    pub override fn touch(step: int) -> int {
        self.tag = self.tag + step * 2
        return self.tag
    }
}

// A generic base with a describable initializer, and a plain subclass that
// writes none of its own. `type_of(Plain)` names exactly one class and one
// body, so this one IS constructible reflectively — and `new Plain()` in
// ordinary code used to fail the BUILD asking for `main::Base.init`.
pub class Base<T> { pub mark: int = 5; pub fn init() {} }
pub class Plain extends Base<int> { pub start: int = 41 }

// A record receiver is bare bytes with no descriptor, so `Spot<int>` and
// `Spot<Wide>` arrive indistinguishable while their slots differ.
pub struct Spot<T> { pub value: T; pub moves: int }

pub enum Choice<T> { first, second(payload: T) }

fn call(name: string, owner: reflect.Type, receiver: reflect.Value,
        method: string, move args: List<reflect.Value>) {
    match owner.method(method) {
        some(m) => {
            match m.call(receiver, move args) {
                ok(_) => io.println("{name}: ok"),
                err(e) => io.println("{name}: {e.kind()} {e.message()}"),
            }
        }
        none => io.println("{name}: no such method"),
    }
}

fn call_static(name: string, owner: reflect.Type, method: string) {
    match owner.method(method) {
        some(m) => {
            match m.call_static([]) {
                ok(_) => io.println("{name}: ok"),
                err(e) => io.println("{name}: {e.kind()} {e.message()}"),
            }
        }
        none => io.println("{name}: no such method"),
    }
}

fn read(name: string, owner: reflect.Type, receiver: reflect.Value,
        field: string) {
    match owner.field(field) {
        some(f) => {
            match f.get(receiver) {
                ok(v) => io.println("{name}: ok {(v as? int).or(-1)}"),
                err(e) => io.println("{name}: {e.kind()} {e.message()}"),
            }
        }
        none => io.println("{name}: no such field"),
    }
}

fn write(name: string, owner: reflect.Type, receiver: reflect.Value,
         field: string, value: reflect.Value) {
    match owner.field(field) {
        some(f) => {
            match f.set(receiver, value) {
                ok(_) => io.println("{name}: ok"),
                err(e) => io.println("{name}: {e.kind()} {e.message()}"),
            }
        }
        none => io.println("{name}: no such field"),
    }
}

fn build(name: string, subject: reflect.Type) {
    match subject.initializer() {
        some(i) => {
            match i.call([]) {
                ok(v) => io.println(
                    "{name}: built {v.type().qualified_name()}"),
                err(e) => io.println("{name}: {e.kind()} {e.message()}"),
            }
        }
        none => io.println("{name}: no initializer"),
    }
}

fn main() {
    var narrow: Cell<int> = new Cell<int>(7)
    var wide: Cell<Wide> = new Cell<Wide>(Wide { a: 1, b: 2, c: 3 })
    var sub: Doubling<int> = new Doubling<int>(4)
    let vnarrow: reflect.Value = reflect.value(narrow)
    let vwide: reflect.Value = reflect.value(wide)
    let vsub: reflect.Value = reflect.value(sub)

    // reachable: a receiver names its instantiation, and the signature
    // reaches no type parameter
    call("touch narrow", type_of(Bumped), vnarrow, "touch",
         [reflect.value(3)])
    call("touch wide", type_of(Bumped), vwide, "touch", [reflect.value(5)])
    call("touch override", type_of(Bumped), vsub, "touch",
         [reflect.value(3)])
    call("note narrow", type_of(Bumped), vnarrow, "note",
         [reflect.value("n")])
    call("note wide", type_of(Bumped), vwide, "note", [reflect.value("w")])
    io.println("after calls: {narrow.tag} {wide.tag} {sub.tag} "
               "{narrow.trail} {wide.trail}")

    // reachable fields at two offsets
    read("read narrow tag", type_of(Cell<int>), vnarrow, "tag")
    read("read wide tag", type_of(Cell<Wide>), vwide, "tag")
    write("write narrow tag", type_of(Cell<int>), vnarrow, "tag",
          reflect.value(30))
    write("write wide tag", type_of(Cell<Wide>), vwide, "tag",
          reflect.value(40))
    read("reread narrow tag", type_of(Cell<int>), vnarrow, "tag")
    read("reread wide tag", type_of(Cell<Wide>), vwide, "tag")
    io.println("after writes: {narrow.tag} {wide.tag} "
               "{narrow.item} {wide.item.a},{wide.item.b},{wide.item.c}")

    // refused: the signature reaches a type parameter
    call("widen narrow", type_of(Cell<int>), vnarrow, "widen",
         [reflect.value(1)])
    read("read narrow item", type_of(Cell<int>), vnarrow, "item")
    write("write narrow item", type_of(Cell<int>), vnarrow, "item",
          reflect.value(2))

    // refused: no receiver names which instantiation's body to run
    call_static("static stamp int", type_of(Cell<int>), "stamp")
    call_static("static stamp wide", type_of(Cell<Wide>), "stamp")

    // refused: a record receiver carries no descriptor
    var spot: Spot<int> = Spot { value: 3, moves: 9 }
    let vspot: reflect.Value = reflect.value(spot)
    read("read spot moves", type_of(Spot<int>), vspot, "moves")

    // refused: an enum variant is made without a receiver
    match type_of(Choice<int>).variant("first") {
        some(v) => {
            match v.make([]) {
                ok(_) => io.println("variant first: ok"),
                err(e) => io.println(
                    "variant first: {e.kind()} {e.message()}"),
            }
        }
        none => io.println("variant first: none"),
    }

    // a generic declaration has no initializer row at all; a plain subclass
    // of a closed one does
    build("Cell<int> init", type_of(Cell<int>))
    build("Base<int> init", type_of(Base<int>))
    build("Plain init", type_of(Plain))

    // the same body the reflective constructor runs, reached the ordinary
    // way: this program did not BUILD before the fix
    let written: Plain = new Plain()
    io.println("new Plain: {written.start} {written.mark}")
}
