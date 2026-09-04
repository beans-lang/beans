// A receiver written at a generic base has to run the method the object's
// class runs, not the base's own body.
//
// The native emitter had a shortcut: when the receiver's declaration was a
// generic class and the method was one that class declares, it raised
// `{instance}.{method}` and called it outright, skipping the descriptor. But
// `Tag<int>` is only the static type; the runtime class is any non-generic
// subclass, and a subclass that overrides the method replaces the body. The
// direct call then ran the base body while the interpreter dispatched through
// the object — a silent wrong answer, only on the native side. `self.label()`
// inside a base body has the same generic-base receiver, so it was wrong too.
//
// The call goes direct only when nothing can replace the body: no subclass
// overrides it (so every object runs the base body), or the method holds no
// descriptor row at all — a private method, whose slot only its declaring type
// can hold, or a method with its own type parameters, which the checker
// forbids overriding. A base with a non-overriding subclass keeps its direct
// call; only a real override reads the descriptor.
//
// The `arc+` / `arc-` markers pin construct and release counts.
package main

import std.io

class Tag<T> {
    priv held: T
    priv n: int

    fn init(held: T, n: int) {
        self.held = held
        self.n = n
        io.println("arc+t{n}")
    }

    fn deinit() { io.println("arc-t{self.n}") }

    // a private method: its slot is Tag's alone, so the base body calling it
    // must reach Tag's, even for a subclass with its own same-named private
    priv fn helper() -> string { return "h{self.n}" }

    fn label() -> string { return "tag:{self.helper()}" }

    // self.label() has a generic-base receiver too, so it must dispatch
    fn describe() -> string { return "[{self.label()}]" }

    // a method with its own type parameters: slot-less, cannot be overridden
    fn wrap<U>(x: U) -> int { return 2 }

    pub fn held_is() -> T { return self.held }
}

class Named extends Tag<int> {
    fn init() { super.init(1, 1) }

    override fn label() -> string { return "named" }

    // a same-named private: a separate method, must not shadow Tag's helper
    priv fn helper() -> string { return "sub" }

    fn own() -> string { return self.helper() }
}

// a subclass that does not override: it inherits the base body and keeps the
// direct call
class Plain extends Tag<int> {
    fn init() { super.init(2, 2) }
}

fn via_label(t: Tag<int>) -> string { return t.label() }
fn via_desc(t: Tag<int>) -> string { return t.describe() }
fn via_wrap(t: Tag<int>) -> int { return t.wrap<string>("x") }

fn main() {
    let named: Named = new Named()
    let plain: Plain = new Plain()
    let base: Tag<int> = new Tag<int>(9, 9)

    // written at each object's own type
    io.println("direct {named.label()} {plain.label()} {base.label()}")

    // written at the generic base — the shape that ran the wrong method
    io.println("vlabel {via_label(named)} {via_label(plain)} {via_label(base)}")

    // self.label() inside the base body dispatches through the object
    io.println("vdesc {via_desc(named)} {via_desc(plain)} {via_desc(base)}")

    // an own-generic (slot-less) method through the base type
    io.println("vwrap {via_wrap(named)} {via_wrap(plain)} {via_wrap(base)}")

    // a subclass's own same-named private reaches its own, not the base's
    io.println("own {named.own()}")

    // payloads travel intact through the base type
    io.println("held {named.held_is()} {plain.held_is()} {base.held_is()}")

    // provably a single concrete class: the devirtualized path still fires
    let dv: Tag<int> = new Named()
    io.println("devirt {via_label(dv)} {via_desc(dv)}")
}
