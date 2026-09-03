// A call the table really does decide still gets a switch on the class id
// when few enough classes can be behind it. Which classes those are is a
// property of the program, so it must not depend on where in the emit the
// call's body happens to sit: every call below is declared before anything
// builds the classes it speculates on, and `late_*` twins are declared
// after, so the two must come out the same.
//
// Getting the arms wrong is not a slow program, it is the wrong method or a
// call that does not match the callee's signature, so devirtualize.sh pins
// the arm count of every call here and the answers are diffed against the
// interpreter, which dispatches through the object every time.
package main

import std.io

// ---- two built implementors, one the program never builds ---------------
// NeverOp keeps the row genuinely undecided — three symbols share the slot,
// so nothing is settled — while never standing behind a receiver, so it
// earns no arm of its own.

interface Op {
    fn apply(x: int) -> int
}

class AddOp implements Op {
    amount: int

    fn init(amount: int) { self.amount = amount }

    fn apply(x: int) -> int { return self.amount + x }
}

class MulOp implements Op {
    amount: int

    fn init(amount: int) { self.amount = amount }

    fn apply(x: int) -> int { return self.amount * x }
}

class NeverOp implements Op {
    fn init() {}

    fn apply(x: int) -> int { return 0 }
}

fn early_op(value: Op) -> int { return value.apply(10) }

// the only place an Op is ever built, between the twins
fn build_ops() -> List<Op> {
    return [new AddOp(3), new MulOp(5)]
}

fn late_op(value: Op) -> int { return value.apply(10) }

// ---- exactly at the arm limit, and one past it --------------------------

interface Quad {
    fn name() -> string
}

class Q1 implements Quad {
    fn init() {}
    fn name() -> string { return "q1" }
}

class Q2 implements Quad {
    fn init() {}
    fn name() -> string { return "q2" }
}

class Q3 implements Quad {
    fn init() {}
    fn name() -> string { return "q3" }
}

class Q4 implements Quad {
    fn init() {}
    fn name() -> string { return "q4" }
}

fn quad_name(value: Quad) -> string { return value.name() }

interface Quint {
    fn name() -> string
}

class P1 implements Quint {
    fn init() {}
    fn name() -> string { return "p1" }
}

class P2 implements Quint {
    fn init() {}
    fn name() -> string { return "p2" }
}

class P3 implements Quint {
    fn init() {}
    fn name() -> string { return "p3" }
}

class P4 implements Quint {
    fn init() {}
    fn name() -> string { return "p4" }
}

class P5 implements Quint {
    fn init() {}
    fn name() -> string { return "p5" }
}

fn quint_name(value: Quint) -> string { return value.name() }

// ---- a row raised on demand may not be named ----------------------------
// Shelf's body is a template raised under each subclass's own name partway
// through the emit, so the row Boxed's descriptor ends up holding is not the
// row an arm could read here. Named writes its own body, which the symbol
// pre-pass files under Named's own name and nothing can displace, so its arm
// stands. Boxed takes the fallback and reads the table.
//
// The receiver is written at Boxed, not at Shelf<int>: a receiver written at
// a generic base calls the base body directly on the native backend today,
// which is issue #103 and has nothing to do with this.

class Shelf<T> {
    held: T

    fn init(held: T) { self.held = held }

    fn tag() -> string { return "shelf" }
}

class Boxed extends Shelf<int> {
    fn init() { super.init(1) }
}

class Named extends Boxed {
    fn init() { super.init() }

    override fn tag() -> string { return "named" }
}

// Deep writes nothing of its own either, so its copy of the inherited body
// is raised when main builds one — after shelf_tag has been emitted.
class Deep extends Boxed {
    fn init() { super.init() }
}

// This runs first and raises Boxed's copy, which is what makes the hazard
// live: with no raise at all the row reads null and the class drops out on
// its own, but with Boxed's copy in hand a rule that did not ask whether the
// row was fixed would hand Deep the symbol raised for Boxed, and Deep's
// descriptor ends up holding its own.
fn warm_shelf() -> string { return new Boxed().tag() }

fn shelf_tag(value: Boxed) -> string { return value.tag() }

// ---- another instantiation is another receiver --------------------------
// IntSource and TextSource share the slot but not the signature. An arm for
// the wrong one would be a call that returns a string read as an int; the
// classes conform to Source by name, so only the arguments rule it out.

interface Source<T> {
    fn make() -> T
}

class IntSource implements Source<int> {
    fn init() {}

    fn make() -> int { return 7 }
}

class TextSource implements Source<string> {
    fn init() {}

    fn make() -> string { return "seven" }
}

fn read_int(value: Source<int>) -> int { return value.make() }

fn read_text(value: Source<string>) -> string {
    return value.make()
}

// ---- a singleton is built without any `new` -----------------------------
// Nothing writes `new Bell()` — the accessor allocates it — so a rule that
// waits for a `new` to be emitted never counts it at all.

interface Chime {
    fn ring() -> string
}

singleton class Bell implements Chime {
    fn init() {}

    fn ring() -> string { return "bell" }
}

class Gong implements Chime {
    fn init() {}

    fn ring() -> string { return "gong" }
}

fn sound(value: Chime) -> string { return value.ring() }

// ---- abstract, and a subclass nobody builds -----------------------------

abstract class Node {
    fn init() {}

    abstract fn label() -> string
}

class RealNode extends Node {
    fn init() { super.init() }

    override fn label() -> string { return "real" }
}

class UnbuiltNode extends Node {
    fn init() { super.init() }

    override fn label() -> string { return "unbuilt" }
}

fn node_label(value: Node) -> string { return value.label() }

// ---- a construction on a path that is never taken -----------------------
// The branch never runs, but the program does contain the construction, so
// the class is one a receiver can hold and keeps its arm.

interface Tone {
    fn note() -> string
}

class Common implements Tone {
    fn init() {}

    fn note() -> string { return "common" }
}

class Rare implements Tone {
    fn init() {}

    fn note() -> string { return "rare" }
}

fn tone_note(value: Tone) -> string { return value.note() }

fn pick_tone(rare: bool) -> Tone {
    if rare { return new Rare() }
    return new Common()
}

fn main() {
    var total: int = 0
    for one: Op in build_ops() {
        total += early_op(one) + late_op(one)
    }
    io.println(total)

    var quads: List<Quad> = [new Q1(), new Q2(), new Q3(), new Q4()]
    var quad_line: string = ""
    for one: Quad in quads {
        quad_line = "{quad_line}{quad_name(one)},"
    }
    io.println(quad_line)

    var quints: List<Quint> =
        [new P1(), new P2(), new P3(), new P4(), new P5()]
    var quint_line: string = ""
    for one: Quint in quints {
        quint_line = "{quint_line}{quint_name(one)},"
    }
    io.println(quint_line)

    io.println(warm_shelf())
    io.println(shelf_tag(new Boxed()))
    io.println(shelf_tag(new Named()))
    io.println(shelf_tag(new Deep()))

    io.println("{read_int(new IntSource())}")
    io.println(read_text(new TextSource()))

    io.println(sound(Bell.instance))
    io.println(sound(new Gong()))

    io.println(node_label(new RealNode()))

    io.println(tone_note(pick_tone(false)))
    io.println(tone_note(pick_tone(true)))
}
