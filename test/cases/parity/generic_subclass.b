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

// ---- J: the same override, with *no* non-generic class anywhere below the
// base. Section I is answered through the concrete leaf's chain walk, so it
// still passes when a generic class cannot be a candidate at all; here the
// generic subclass is the only class that can stand behind the receiver, and
// it is matched against `JBase<int>` by arguments it writes as `JBase<T>`.
// Comparing those as written says no, the candidate is skipped, and the call
// is compiled direct to the base body — the override never runs. Two
// instantiations, and a second generic link below the first, so the walk has
// more than one link to weigh.
class JBase<T> {
    v: T
    fn init(v: T) { self.v = v }
    fn heft() -> int { return 1 }
}
class JSub<T> extends JBase<T> {
    fn init(v: T) { super.init(v) }
    override fn heft() -> int { return 2 }
}
class JMore<T> extends JSub<T> {
    fn init(v: T) { super.init(v) }
    override fn heft() -> int { return 3 }
}
fn j_heft(b: JBase<int>) -> int { return b.heft() }
fn j_heft_str(b: JBase<string>) -> int { return b.heft() }

// ---- K: a strong cycle held in a T-typed field, and a five-link chain that
// alternates plain and generic with one generic class nested inside another.
// The cycle is the pointer mask under the collector rather than under scope
// exit: `KCell<KPay>` traces its held field and `KCell<int>` must not, and the
// two are the same generic class. The chain is there because a generic link
// can sit anywhere — above a plain one, below one, between two — and each
// arrangement lays the fields out through a different composition.
class KPay {
    tag: string
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
}
class KRoot { fn init() {} }
class KCell<T> extends KRoot {
    n: int
    held: T
    other: Option<KCell<T>> = none
    fn init(n: int, held: T) {
        self.n = n
        self.held = held
        super.init()
    }
}
class L0 { fn init() {} fn who() -> string { return "L0" } }
class L1<T> extends L0 {
    a: T
    fn init(a: T) { self.a = a; super.init() }
}
class L2 extends L1<int> {
    b: string
    fn init() { self.b = "L2"; super.init(2) }
}
class L3<T> extends L2 {
    c: T
    fn init(c: T) { self.c = c; super.init() }
    override fn who() -> string { return "L3" }
}
class L4<T> extends L3<T> {
    d: int
    fn init(c: T) { self.d = 4; super.init(c) }
}
class L5 extends L4<string> {
    fn init() { super.init("five") }
}
fn who_of(x: L0) -> string { return x.who() }

// ---- L: the three things the spec now promises about an instantiation, with
// every instantiation of one generic class live in the same program.
//
//   own field offsets  — `held: T` is 8 bytes at `int`, 8 at `string` and 16 at
//                        a two-int struct, so `after` sits at a different byte
//                        in each; one shared layout reads the wrong bytes back
//   own method table   — `get()` is inherited, not overridden, and returns `T`,
//                        so each instantiation runs a different raised body
//   own row in the walk `as?` reads — a non-generic leaf under each is a type
//                        of its own, and neither the other leaf nor a bare
//                        instantiation answers to it
struct LPair {
    a: int
    b: int
}
class LBase {
    seq: int
    fn init(seq: int) { self.seq = seq }
}
class LSub<T> extends LBase {
    held: T
    after: int
    fn init(seq: int, held: T, after: int) {
        self.held = held
        self.after = after
        super.init(seq)
    }
    fn get() -> T { return self.held }
    fn width() -> int { return self.after }
}
class LIntLeaf extends LSub<int> {
    fn init() { super.init(1, 11, 101) }
}
class LStrLeaf extends LSub<string> {
    fn init() { super.init(2, "ss", 202) }
}
fn l_is_int(b: LBase) -> string {
    match b as? LIntLeaf {
        some(found) => { return "i" }
        none => { return "-" }
    }
}
fn l_is_str(b: LBase) -> string {
    match b as? LStrLeaf {
        some(found) => { return "s" }
        none => { return "-" }
    }
}

// ---- M: `as?` from a receiver written at an instantiation. The source is
// only a static type — the test reads the object's runtime class — so an
// instantiation is as good a source as a plain class, and this is the one
// downcast a generic hierarchy can express. The target must stay non-generic:
// a run-time test cannot tell `MBox<int>` from `MBox<string>`, because an
// object does not carry its type arguments, so the checker refuses that
// (test/cases/generic_downcast_bad.b pins the refusal and says why).
//
// Both instantiations are live and each has its own leaves, so an answer that
// ignored the arguments would show up here.
class MBox<T> {
    v: T
    fn init(v: T) { self.v = v }
}
class MIntLeaf extends MBox<int> {
    fn init() { super.init(1) }
}
class MIntOther extends MBox<int> {
    fn init() { super.init(2) }
}
class MStrLeaf extends MBox<string> {
    fn init() { super.init("s") }
}
class MDeep extends MIntLeaf {
    fn init() { super.init() }
}
fn m_int(b: MBox<int>) -> string {
    match b as? MIntLeaf {
        some(found) => { return "L" }
        none => { return "-" }
    }
}
fn m_str(b: MBox<string>) -> string {
    match b as? MStrLeaf {
        some(found) => { return "S" }
        none => { return "-" }
    }
}

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

    // J — the override on a generic subclass with no plain class below it
    io.println("J {j_heft(new JBase<int>(1))} {j_heft(new JSub<int>(2))}")
    io.println("J {j_heft(new JMore<int>(3))} {j_heft_str(new JSub<string>("t"))}")

    // K — a cycle through a traced T, an int T that must not be traced, and
    // a five-link chain with a generic class nested inside another
    // both payloads carry the same tag: the order two objects of one killed
    // cycle are released in is not specified, and pinning it would assert
    // something neither backend promises. What is asserted is that each is
    // released exactly once, which the marker balance carries.
    let k1: KCell<KPay> = new KCell<KPay>(1, new KPay("k_cyc"))
    let k2: KCell<KPay> = new KCell<KPay>(2, new KPay("k_cyc"))
    k1.other = some(k2)
    k2.other = some(k1)
    let k3: KCell<int> = new KCell<int>(3, 7)
    io.println("K {k1.n} {k2.n} {k3.n} {k3.held} {k1.held.tag} {k2.held.tag}")
    let l1: L4<int> = new L4<int>(9)
    let l2: L4<string> = new L4<string>("nine")
    let l3: L5 = new L5()
    let nested: L1<L4<int>> = new L1<L4<int>>(new L4<int>(11))
    io.println("K {l1.a} {l1.b} {l1.c} {l1.d} {l2.c} {l3.c} {l3.d}")
    io.println("K {who_of(l1)} {who_of(l3)} {who_of(new L2())} {nested.a.c} {nested.a.d}")

    // L — own field offsets: `after` follows a T of three different widths,
    // and the base's own `seq` sits ahead of all of them
    let m1: LSub<int> = new LSub<int>(3, 33, 303)
    let m2: LSub<string> = new LSub<string>(4, "qq", 404)
    let m3: LSub<LPair> = new LSub<LPair>(5, LPair { a: 55, b: 56 }, 505)
    io.println("L {m1.seq} {m1.held} {m1.after} {m2.seq} {m2.held} {m2.after}")
    io.println("L {m3.seq} {m3.held.a} {m3.held.b} {m3.after} {m3.width()}")
    // L — own method table: `get` is inherited and returns T, so each
    // instantiation runs its own raised body
    io.println("L {m1.get()} {m2.get()} {m3.get().b} {m1.width()} {m2.width()}")
    // L — own row in the class-parent walk: each leaf answers only to itself,
    // and a bare instantiation answers to neither
    let mi: LIntLeaf = new LIntLeaf()
    let ms: LStrLeaf = new LStrLeaf()
    io.println("L {l_is_int(mi)}{l_is_str(mi)} {l_is_int(ms)}{l_is_str(ms)} {l_is_int(m1)}{l_is_str(m2)}")
    io.println("L {mi.get()} {mi.after} {ms.get()} {ms.after} {mi.seq} {ms.seq}")

    // M — `as?` from a receiver written at an instantiation, to a plain class
    // under it. MDeep is below MIntLeaf, so it answers too; MIntOther does not.
    io.println("M {m_int(new MIntLeaf())} {m_int(new MIntOther())} {m_int(new MDeep())} {m_int(new MBox<int>(3))}")
    io.println("M {m_str(new MStrLeaf())} {m_str(new MBox<string>("t"))}")
    io.println("made")
}
