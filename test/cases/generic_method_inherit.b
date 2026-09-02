// A method that declares type parameters of its own binds them at the call
// site, so it is a template until then: no descriptor row can hold every
// instantiation and no receiver picks it. The receiver's static type decides
// which body runs, and that body may be one a base declares.
//
// Before #89 the emitter looked for the template under the receiver's own
// declaration only. A subclass that inherited one found nothing, fell through
// to dispatch, and read a row that was never going to be filled — a literal
// null in the descriptor, jumped through. The interpreter answered the whole
// time, so its answers are the reference here.
//
// Every receiver below arrives as a parameter first, so no allocation is in
// sight and the call has to be decided from the type alone; the same calls
// follow on a receiver whose `new` is right there, which takes the other
// path through the emitter.
package main

import std.io

class Base {
    tag: string

    fn init(tag: string) { self.tag = tag }

    // the type parameter reaches the result, so each instantiation is a
    // different function and a shared name would collide
    fn pick<T>(value: T) -> T { return value }

    // and one that reads the receiver, so a body raised for a subclass
    // still has to find its own fields
    fn label<T>(value: T) -> string { return "{self.tag}.label" }

    fn plain() -> string { return "{self.tag}.plain" }

    // `priv` scopes a name to its exact declaring type, so a subclass may
    // wear it too — the only way one family can now hold two generic
    // methods under one name. The body this calls is Base's whatever the
    // receiver's runtime class is: the method holds no row, so the runtime
    // class never enters into it.
    priv fn mark<T>(value: T) -> string { return "Base.mark" }

    fn shows() -> string { return self.mark<int>(1) }
}

class Sub extends Base {
    fn init() { super.init("Sub") }

    // reached through `self` from a body the subclass declares
    fn via_self() -> int { return self.pick<int>(7) }

    // a `priv` method belongs to its exact type, so this shadows nothing
    // and the walk has to stop at the nearest owner that declares the name
    priv fn own<T>(value: T) -> string { return "Sub.own" }

    fn via_own() -> string { return self.own<int>(1) }

    priv fn mark<T>(value: T) -> string { return "Sub.mark" }

    fn via_mark() -> string { return self.mark<int>(2) }
}

class Mid extends Base {
    fn init(tag: string) { super.init(tag) }
}

class Leaf extends Mid {
    fn init() { super.init("Leaf") }
}

// A generic base pinned at two different arguments. The inherited template
// carries the owner's parameter and the method's at once, so each subclass
// raises its own instantiation and the two must not share a name.
class Holder<E> {
    value: E

    fn init(value: E) { self.value = value }

    fn hold<T>(other: T) -> T { return other }

    // answers the owner's parameter, which only the `extends` pinned
    fn keep<T>(other: T) -> E { return self.value }
}

class IntHolder extends Holder<int> {
    fn init(value: int) { super.init(value) }
}

class StrHolder extends Holder<string> {
    fn init(value: string) { super.init(value) }
}

// two links below a generic base
class DeepIntHolder extends IntHolder {
    fn init() { super.init(5) }
}

fn ask_sub(value: Sub) -> int { return value.pick<int>(1) }

// `shows` dispatches, so a Sub receiver runs Base's body; the generic method
// that body calls does not, so it stays Base's too
fn ask_shows(value: Base) -> string { return value.shows() }

fn ask_leaf(value: Leaf) -> string { return value.pick<string>("leaf") }

fn ask_base(value: Base) -> bool { return value.pick<bool>(true) }

fn ask_label(value: Leaf) -> string { return value.label<int>(0) }

fn ask_int_holder(value: IntHolder) -> int { return value.keep<string>("s") }

fn ask_str_holder(value: StrHolder) -> string { return value.keep<int>(9) }

fn ask_deep(value: DeepIntHolder) -> int { return value.keep<bool>(true) }

fn ask_deep_hold(value: DeepIntHolder) -> string {
    return value.hold<string>("held")
}

fn main() {
    // one link, two links, and the declaring class itself
    io.println("{ask_sub(new Sub())}")
    io.println(ask_leaf(new Leaf()))
    io.println("{ask_base(new Base("Base"))}")
    // a base-typed parameter holding a subclass: the body is the base's
    // either way, because a generic method does not dispatch
    io.println("{ask_base(new Sub())}")
    io.println(ask_label(new Leaf()))

    // the owner's parameter pinned two ways, and once two links down
    io.println("{ask_int_holder(new IntHolder(3))}")
    io.println(ask_str_holder(new StrHolder("kept")))
    io.println("{ask_deep(new DeepIntHolder())}")
    io.println(ask_deep_hold(new DeepIntHolder()))

    // the same calls where the receiver's `new` is in sight, which reaches
    // the emitter's exact-receiver path instead
    io.println("{new Sub().pick<int>(2)}")
    io.println(new Leaf().pick<string>("direct"))
    io.println("{new DeepIntHolder().keep<int>(0)}")
    io.println(new DeepIntHolder().hold<string>("direct"))

    // through `self`, and through a `priv` template of the subclass's own
    io.println("{new Sub().via_self()}")
    io.println(new Sub().via_own())

    // several instantiations off one inherited template
    io.println(new Sub().pick<string>("a"))
    io.println("{new Sub().pick<bool>(false)}")
    io.println("{new Sub().pick<int>(3)}")

    // a dispatching body reaching its own `priv` template, on a receiver
    // whose runtime class declares one of the same name
    io.println(ask_shows(new Base("Base")))
    io.println(ask_shows(new Sub()))
    io.println(ask_shows(new Leaf()))
    io.println(new Sub().via_mark())

    // and the ordinary method beside it still dispatches
    io.println(new Sub().plain())
    io.println(new Leaf().plain())
}
