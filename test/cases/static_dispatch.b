// Which method a call reaches must never depend on whether the emitter was
// able to name it. Every receiver below is reached through a parameter, so
// no allocation is in sight and the exact-receiver analysis cannot help: the
// only question left is whether the descriptor row for the call's slot can
// hold more than one symbol.
//
// The interpreter dispatches through the object every single time, so its
// answers are the reference the native build has to match line for line.
package main

import std.io

// ---- a private method belongs to its declaring type ----------------------
// `priv` puts the slot under the exact type, so SubLedger.stamp is a
// different method, not an override, and Ledger.record keeps calling its own.

class Ledger {
    tag: string

    fn init(tag: string) { self.tag = tag }

    priv fn stamp() -> string { return "Ledger.stamp" }

    fn record() -> string { return "{self.tag}/{self.stamp()}" }
}

class SubLedger extends Ledger {
    fn init(tag: string) { super.init(tag) }

    priv fn stamp() -> string { return "SubLedger.stamp" }

    fn own() -> string { return "own/{self.stamp()}" }
}

// ---- an override has to stay dynamic -------------------------------------
// Five bodies share `speak`, which is past the guarded switch's arm limit,
// so the call has to read the table. `twice` is never replaced, so the call
// that reaches it is settled even though what it calls is not.

class Animal {
    fn init() {}

    fn speak() -> string { return "Animal" }

    fn twice() -> string { return "{self.speak()}+{self.speak()}" }
}

class Dog extends Animal {
    fn init() { super.init() }

    override fn speak() -> string { return "Dog" }
}

class Cat extends Animal {
    fn init() { super.init() }

    override fn speak() -> string { return "Cat" }
}

class Fox extends Animal {
    fn init() { super.init() }

    override fn speak() -> string { return "Fox" }
}

class Owl extends Animal {
    fn init() { super.init() }

    override fn speak() -> string { return "Owl" }
}

// three deep, and reaching the middle body through `super`
class Puppy extends Dog {
    fn init() { super.init() }

    override fn speak() -> string { return "Puppy<{super.speak()}>" }
}

// ---- an inherited method nobody replaces ---------------------------------
// Root.kind is the only body in the family, so Root, Mid and Leaf receivers
// all settle on it — a base-typed receiver included.

class Root {
    fn init() {}

    fn kind() -> string { return "Root.kind" }
}

class Mid extends Root {
    fn init() { super.init() }
}

class Leaf extends Mid {
    fn init() { super.init() }
}

// ---- a leaf class with no family at all ----------------------------------

class Solo {
    fn init() {}

    pub fn name() -> string { return "Solo" }
}

// ---- interfaces ----------------------------------------------------------
// Two implementors keep the table in charge; one implementor settles.

interface Sink {
    fn accept(value: int) -> string
}

class Loud implements Sink {
    fn init() {}

    fn accept(value: int) -> string { return "Loud{value}" }
}

class Quiet implements Sink {
    fn init() {}

    fn accept(value: int) -> string { return "Quiet{value}" }
}

interface Only {
    fn once() -> string
}

class TheOnly implements Only {
    fn init() {}

    fn once() -> string { return "TheOnly" }
}

// ---- abstract classes ----------------------------------------------------
// An abstract class is never built, so it is never the class a receiver's
// descriptor names: one concrete subclass settles the call, two do not.

abstract class Task {
    abstract fn run() -> string

    fn go() -> string { return "go/{self.run()}" }
}

class OnlyTask extends Task {
    fn init() {}

    override fn run() -> string { return "OnlyTask" }
}

abstract class Job {
    abstract fn work() -> string

    fn start() -> string { return "start/{self.work()}" }
}

class Fast extends Job {
    fn init() {}

    override fn work() -> string { return "Fast" }
}

class Slow extends Job {
    fn init() {}

    override fn work() -> string { return "Slow" }
}

// ---- a generic implementor never settles ---------------------------------
// A generic class fills its rows per instantiation, so one declaration is
// many tables and no single symbol stands for the interface.

interface Producer {
    fn make() -> string
}

class PlainMaker implements Producer {
    fn init() {}

    fn make() -> string { return "PlainMaker" }
}

class BoxMaker<T> implements Producer {
    held: T

    fn init(held: T) { self.held = held }

    fn make() -> string { return "BoxMaker" }
}

// ---- interface default bodies --------------------------------------------
// The default belongs to the interface, so the row a class keeps names the
// interface's own symbol; a class that replaces it puts two in play.

interface Greeter {
    fn who() -> string

    fn greet() -> string { return "hi {self.who()}" }
}

class OneGreeter implements Greeter {
    fn init() {}

    fn who() -> string { return "one" }
}

interface Caller {
    fn who() -> string

    fn shout() -> string { return "HEY {self.who()}" }
}

class Softly implements Caller {
    fn init() {}

    fn who() -> string { return "softly" }
}

class Harshly implements Caller {
    fn init() {}

    fn who() -> string { return "harshly" }

    override fn shout() -> string { return "RUDE" }
}

// ---- a compiler-known interface owns no rows -----------------------------
// `Eq` has no declaration of its own, so it can hold no body and move no
// row. A class that names one settles like any other, which the whole
// standard library depends on: `implements Eq & Hash & Clone` is how a type
// becomes a map key.

class Point implements Eq {
    x: int

    fn init(x: int) { self.x = x }

    priv fn doubled() -> int { return self.x * 2 }

    fn equals(other: Point) -> bool { return self.x == other.x }

    fn shown() -> string { return "Point{self.doubled()}" }
}

// ---- a method with generics of its own is raised, not tabled -------------
// `pick` has no descriptor row at all: it binds its own type at each call
// site, so its symbol is raised per instantiation under the template's own
// name and can appear at any point in the emit. A subclass receiver must
// not settle on whichever instantiation happened to be raised first — the
// answer would be another call site's type arguments.
//
// `raise_tally` runs first and raises the int instantiation, so by the time
// `ask_generic` is emitted the template's own name does hold a symbol —
// which is the whole hazard, and without the check `ask_generic` would bind
// to it and pass a string where that instantiation reads an int.
//
// `ask_generic` is deliberately never called: dispatching an inherited
// generic method through a subclass reads a row that was never filled, and
// that is a separate native fault. What is pinned here is the emitted form.

class Tally {
    fn init() {}

    fn pick<T>(value: T) -> int { return 1 }

    fn count() -> int { return 3 }
}

class SubTally extends Tally {
    fn init() { super.init() }
}

fn raise_tally(value: Tally) -> int {
    return value.pick<int>(1)
}

fn ask_generic(value: SubTally) -> int {
    return value.pick<string>("s")
}

// ---- a generic base raises its bodies on demand --------------------------
// A class extending a generic base has no symbol for the inherited body
// until some call site raises the instance under that subclass's own name,
// which happens partway through the emit and separately for each subclass.
// The row a call reads before the raise is not the row the descriptor ends
// up holding, so nothing in this family may settle.

class Store<T> {
    held: T

    fn init(held: T) { self.held = held }

    fn note() -> string { return "Store.note" }
}

class IntStore extends Store<int> {
    fn init() { super.init(1) }
}

class DeepStore extends IntStore {
    fn init() { super.init() }
}

// ---- reached through a parameter, never through an allocation ------------

fn via_ledger(value: Ledger) -> string { return value.record() }

fn via_subledger(value: SubLedger) -> string { return value.own() }

fn via_animal(value: Animal) -> string { return value.twice() }

fn via_dog(value: Dog) -> string { return value.twice() }

fn via_root(value: Root) -> string { return value.kind() }

fn via_mid(value: Mid) -> string { return value.kind() }

fn via_leaf(value: Leaf) -> string { return value.kind() }

fn via_solo(value: Solo) -> string { return value.name() }

fn via_sink(value: Sink) -> string { return value.accept(7) }

fn via_only(value: Only) -> string { return value.once() }

fn via_task(value: Task) -> string { return value.go() }

fn via_job(value: Job) -> string { return value.start() }

fn via_producer(value: Producer) -> string { return value.make() }

fn via_greeter(value: Greeter) -> string { return value.greet() }

fn via_caller(value: Caller) -> string { return value.shout() }

fn via_point(value: Point) -> string { return value.shown() }

fn via_tally(value: SubTally) -> int { return value.count() }

fn via_intstore(value: IntStore) -> string { return value.note() }

fn via_deepstore(value: DeepStore) -> string { return value.note() }

fn main() {
    io.println(via_ledger(new Ledger("base")))
    io.println(via_ledger(new SubLedger("sub")))
    io.println(via_subledger(new SubLedger("sub")))

    io.println(via_animal(new Animal()))
    io.println(via_animal(new Dog()))
    io.println(via_animal(new Cat()))
    io.println(via_animal(new Fox()))
    io.println(via_animal(new Owl()))
    io.println(via_animal(new Puppy()))
    io.println(via_dog(new Puppy()))

    io.println(via_root(new Root()))
    io.println(via_root(new Leaf()))
    io.println(via_mid(new Leaf()))
    io.println(via_leaf(new Leaf()))

    io.println(via_solo(new Solo()))

    io.println(via_sink(new Loud()))
    io.println(via_sink(new Quiet()))
    io.println(via_only(new TheOnly()))

    io.println(via_task(new OnlyTask()))
    io.println(via_job(new Fast()))
    io.println(via_job(new Slow()))

    io.println(via_producer(new PlainMaker()))
    io.println(via_producer(new BoxMaker<int>(1)))
    io.println(via_producer(new BoxMaker<string>("x")))

    io.println(via_point(new Point(4)))
    io.println(via_tally(new SubTally()))
    io.println(raise_tally(new Tally()))
    io.println(via_intstore(new IntStore()))
    io.println(via_deepstore(new DeepStore()))

    io.println(via_greeter(new OneGreeter()))
    io.println(via_caller(new Softly()))
    io.println(via_caller(new Harshly()))

    // through a list of the interface, so the receiver is an element and
    // every hop reads whatever the table holds
    var sinks: List<Sink> = [new Loud(), new Quiet(), new Loud()]
    var joined: string = ""
    for one: Sink in sinks {
        joined = "{joined}{one.accept(1)}"
    }
    io.println(joined)

    var animals: List<Animal> =
        [new Animal(), new Dog(), new Cat(), new Fox(),
         new Owl(), new Puppy()]
    var voices: string = ""
    for beast: Animal in animals {
        voices = "{voices}{beast.speak()},"
    }
    io.println(voices)
}
