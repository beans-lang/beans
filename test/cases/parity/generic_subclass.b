// Issue #123: a generic class that `extends` anything could not be laid out
// by the native backend at all. `beansc check` passed, the interpreter ran the
// program, and the build then failed talking about the emitter's own metadata
// capacity — on a class with no fields. Fields were never the reason; having a
// base was.
//
// Nothing in test/cases exercised this before, because every generic class
// there either stands alone or is extended by a non-generic subclass — the one
// arrangement that already worked. The OOP fuzzer builds inheritance chains out
// of non-generic classes only, so it could not reach these shapes either.
//
// Each section is at least two instantiations wide: a layout, a pointer mask
// and a symbol key are all per-argument-list, and one instantiation proves
// none of them right.
package main

import std.io

// ---- A: the three field shapes over a plain base, each at two arguments.
// The zero-field case is the one that shows fields were never the reason.
class ARoot {
    tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
    fn kind() -> string { return "aroot" }
}
class AEmpty<T> extends ARoot {
    fn init(tag: string) { super.init(tag) }
}
class APlain<T> extends ARoot {
    n: int
    fn init(tag: string, n: int) {
        self.n = n
        super.init(tag)
    }
}
class AHeld<T> extends ARoot {
    held: T
    fn init(tag: string, held: T) {
        self.held = held
        super.init(tag)
    }
}

// ---- B: dispatch. `speak` is overridden in the generic subclass, `kind` is
// not. Both are reached through a base-typed receiver, so both come out of the
// instantiation's descriptor. The inherited row is the one that used to emit
// null: calling it jumped to address zero and the program took a segfault
// rather than printing a wrong answer.
class BRoot {
    fn init() {}
    fn speak() -> string { return "broot" }
    fn kind() -> string { return "broot-kind" }
}
class BGen<T> extends BRoot {
    label: string
    fn init(label: string) {
        self.label = label
        super.init()
    }
    override fn speak() -> string {
        return "bgen-{self.label}"
    }
}
class BPlain extends BRoot {
    override fn speak() -> string { return "bplain" }
    fn init() { super.init() }
}
fn describe(b: BRoot) -> string {
    return "{b.kind()}/{b.speak()}"
}

// ---- C: a generic class extending a generic base. Same parameter, a pinned
// argument, and two parameters where only the second reaches the base — the
// base's fields have to be laid out at the arguments this link pinned, not at
// the leaf's.
class CBase<T> {
    v: T
    fn init(v: T) { self.v = v }
    fn base_name() -> string { return "cbase" }
    fn render() -> string { return "cbase" }
}
class CSame<T> extends CBase<T> {
    fn init(v: T) { super.init(v) }
}
class CPinned<T> extends CBase<int> {
    other: T
    fn init(other: T) {
        self.other = other
        super.init(7)
    }
}
class CPair<A, B> extends CBase<B> {
    first: A
    fn init(first: A, second: B) {
        self.first = first
        super.init(second)
    }
}

// ---- D: the full chain the issue reported — a non-generic class below a
// generic middle below a generic base, every link chaining through super.init.
// The middle's own `super.init` names a template whose arguments only this
// instantiation knows, which is what the parent-method lookup could not find.
class DBase<T> {
    v: T
    fn init(v: T) { self.v = v }
    fn render() -> string { return "dbase" }
}
class DMid<T> extends DBase<T> {
    fn init(v: T) { super.init(v) }
}
class DOuter extends DMid<int> {
    fn init() { super.init(3) }
}
class DDeep<T> extends DMid<T> {
    fn init(v: T) { super.init(v) }
}

// ---- E: a generic class in the middle of a chain, with a deinit. This is the
// case #119 could not write a test for, because the shape could not be built
// on either backend. The leaf declares none, so its release row is the
// middle's body, which chains into the root's. Each runs once per object.
class ERoot {
    fn init() { io.println("arc+e_root") }
    fn deinit() { io.println("arc-e_root") }
}
class EMid<T> extends ERoot {
    held: T
    fn init(held: T) {
        self.held = held
        super.init()
        io.println("arc+e_mid")
    }
    fn deinit() { io.println("arc-e_mid") }
}
class ELeaf extends EMid<int> {
    fn init() { super.init(1) }
}
class EStr extends EMid<string> {
    fn init() { super.init("s") }
}

// ---- F: the pointer mask. Two instantiations of one generic subclass, one
// holding a reference and one holding an integer, with a non-pointer field
// ahead of the held one so the offset matters. A mask shared between them
// would either leak the cell or release the integer 5 as a pointer.
class FCell {
    tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
}
class FRoot {
    seq: int
    fn init(seq: int) { self.seq = seq }
}
class FBox<T> extends FRoot {
    weight: int
    held: T
    fn init(seq: int, weight: int, held: T) {
        self.weight = weight
        self.held = held
        super.init(seq)
    }
}

// ---- G: `as?` has to walk *through* a generic link. The runtime table maps a
// class id to its parent's id, and a generic class is a different class per
// argument list. Reading the parent off the declaration named the template —
// an id no object carries — so the walk stopped at the generic link and `as?`
// answered none for an object that really was one.
class GRoot { fn init() {} }
class GMid extends GRoot { fn init() { super.init() } }
class GGen<T> extends GMid {
    held: T
    fn init(held: T) {
        self.held = held
        super.init()
    }
}
class GLeaf extends GGen<int> {
    fn init() { super.init(2) }
}
fn is_mid(r: GRoot) -> string {
    match r as? GMid {
        some(found) => { return "mid" }
        none => { return "not-mid" }
    }
}
fn is_leaf(r: GRoot) -> string {
    match r as? GLeaf {
        some(found) => { return "leaf" }
        none => { return "not-leaf" }
    }
}

// ---- H: an override declared on a *generic* subclass of a *generic* base,
// reached through a receiver written at the base. The receiver's static type
// is only a generic base, so the emitter asks whether any class that could
// stand behind it replaces the method — and a generic link answered no twice
// over: its methods were left out of the record of which slots a name
// declares (a template has no symbol, but its class still declares the
// method), and a generic class was matched against the receiver by its
// written arguments, which cannot match `Base<int>` when the class says
// `Base<T>`. The call compiled direct to the base body and ran the wrong
// method, silently, while the interpreter dispatched to the override.
//
// `heft` is the override, `carry` is inherited by every link, and the leaf
// below the generic subclass is non-generic so both conformer shapes are
// weighed. HPlainSub is the arrangement that already worked and must not
// change.
class HBase<T> {
    v: T
    fn init(v: T) { self.v = v }
    fn heft() -> int { return 1 }
    fn carry() -> string { return "hbase" }
}
class HGenSub<T> extends HBase<T> {
    fn init(v: T) { super.init(v) }
    override fn heft() -> int { return 2 }
}
class HLeaf extends HGenSub<int> {
    fn init() { super.init(9) }
}
class HDeepGen<T> extends HGenSub<T> {
    fn init(v: T) { super.init(v) }
    override fn heft() -> int { return 3 }
}
class HPlainSub extends HBase<int> {
    fn init() { super.init(8) }
    override fn heft() -> int { return 4 }
}
fn hefted(b: HBase<int>) -> string {
    return "{b.carry()}/{b.heft()}"
}

// ---- I: the override sits on an *abstract* generic class between the base
// and the concrete leaf. An abstract class is never the runtime class behind a
// receiver, so it is passed over as a candidate — which leaves the concrete
// leaf's chain walk as the only place its override can be noticed, and that
// walk reads the record of which slots a name declares. A template's name got
// no entry in that record, so the override was invisible and the call
// compiled direct to the base body. Two instantiations of the abstract link,
// because the record is keyed by the declaration and one proves nothing about
// the other.
class IBase<T> {
    v: T
    fn init(v: T) { self.v = v }
    fn heft() -> int { return 1 }
}
abstract class IAbs<T> extends IBase<T> {
    fn init(v: T) { super.init(v) }
    override fn heft() -> int { return 2 }
    abstract fn name() -> string
}
class IConc extends IAbs<int> {
    fn init() { super.init(1) }
    override fn name() -> string { return "i-int" }
}
class IStr extends IAbs<string> {
    fn init() { super.init("s") }
    override fn name() -> string { return "i-str" }
}
fn i_heft(b: IBase<int>) -> int { return b.heft() }
fn i_heft_str(b: IBase<string>) -> int { return b.heft() }

fn main() {
    // A — every field shape, twice over
    let a1: AEmpty<int> = new AEmpty<int>("a_empty_int")
    let a2: AEmpty<string> = new AEmpty<string>("a_empty_str")
    let a3: APlain<int> = new APlain<int>("a_plain_int", 4)
    let a4: APlain<string> = new APlain<string>("a_plain_str", 5)
    let a5: AHeld<int> = new AHeld<int>("a_held_int", 6)
    let a6: AHeld<string> = new AHeld<string>("a_held_str", "six")
    io.println("A {a3.n} {a4.n} {a5.held} {a6.held} {a1.kind()} {a2.tag}")

    // B — dispatch through a base-typed receiver
    io.println("B {describe(new BRoot())} {describe(new BPlain())}")
    io.println("B {describe(new BGen<int>("i"))} {describe(new BGen<string>("s"))}")
    let bg: BGen<int> = new BGen<int>("direct")
    io.println("B {bg.kind()} {bg.speak()}")

    // C — generic over generic
    let c1: CSame<int> = new CSame<int>(11)
    let c2: CSame<string> = new CSame<string>("twelve")
    let c3: CPinned<string> = new CPinned<string>("pinned")
    let c4: CPinned<int> = new CPinned<int>(13)
    let c5: CPair<string, int> = new CPair<string, int>("pair", 14)
    let c6: CPair<int, string> = new CPair<int, string>(15, "sixteen")
    io.println("C {c1.render()} {c2.render()} {c1.v} {c2.v} {c3.v} {c3.other} {c4.v} {c4.other}")
    io.println("C {c5.first} {c5.v} {c6.first} {c6.v} {c1.base_name()}")

    // D — a plain leaf under a generic middle, and a generic one
    let d1: DOuter = new DOuter()
    let d2: DDeep<string> = new DDeep<string>("deep")
    let d3: DDeep<int> = new DDeep<int>(17)
    io.println("D {d1.render()} {d2.render()} {d3.render()} {d1.v} {d2.v} {d3.v}")

    // E — a deinit on the generic middle, two instantiations
    let e1: ELeaf = new ELeaf()
    let e2: EStr = new EStr()
    let e3: EMid<int> = new EMid<int>(18)
    io.println("E {e1.held} {e2.held} {e3.held}")

    // F — the pointer mask, per instantiation
    let f1: FBox<FCell> = new FBox<FCell>(1, 2, new FCell("f_cell"))
    let f2: FBox<int> = new FBox<int>(3, 4, 5)
    io.println("F {f1.seq} {f1.weight} {f1.held.tag} {f2.seq} {f2.weight} {f2.held}")

    // G — as? through a generic link
    io.println("G {is_mid(new GRoot())} {is_mid(new GMid())}")
    io.println("G {is_mid(new GGen<int>(19))} {is_mid(new GLeaf())}")
    io.println("G {is_leaf(new GLeaf())} {is_leaf(new GGen<int>(20))}")

    // H — an override on a generic subclass, through a base-typed receiver
    io.println("H {hefted(new HBase<int>(1))} {hefted(new HGenSub<int>(2))}")
    io.println("H {hefted(new HLeaf())} {hefted(new HDeepGen<int>(3))}")
    io.println("H {hefted(new HPlainSub())} {new HGenSub<string>("s").heft()}")

    // I — the override on an abstract generic link
    io.println("I {i_heft(new IConc())} {i_heft(new IBase<int>(2))}")
    io.println("I {i_heft_str(new IStr())} {new IConc().name()} {new IStr().name()}")
    io.println("made")
}
