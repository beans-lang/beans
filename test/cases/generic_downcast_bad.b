// `as?` cannot name a generic instantiation, and the refusal has to say why
// rather than deny a relation that holds: `Sub<int>` really is a child of
// `Base<int>`, so the parent/child message would be a lie.
//
// The reason is that a downcast is decided at run time from the object's own
// class, and the tree interpreter carries no type arguments on an object —
// every instantiation of a class is one runtime name there. Relaxing the check
// makes the two backends disagree: with a `G<string>` held as a plain base,
// the interpreter answers yes to `as? G<int>` and the native backend, which
// numbers each instantiation, answers no. Refusing is the only answer both
// can give. Lifting this means carrying an object's type arguments in the
// interpreter, not changing the emitter — the native side already answers it.
//
// The downcast that *does* work is the other one: a receiver written at an
// instantiation, tested against a non-generic class under it. That is section
// M of test/cases/parity/generic_subclass.b.
package main

class Base<T> {
    v: T
    fn init(v: T) { self.v = v }
}

class Sub<T> extends Base<T> {
    fn init(v: T) { super.init(v) }
}

class Root { fn init() {} }
class G<T> extends Root {
    v: T
    fn init(v: T) { self.v = v; super.init() }
}

fn to_sub(b: Base<int>) -> string {
    match b as? Sub<int> {
        some(found) => { return "sub" }
        none => { return "plain" }
    }
}

fn to_g(r: Root) -> string {
    match r as? G<int> {
        some(found) => { return "g" }
        none => { return "-" }
    }
}

fn main() {
    let a: string = to_sub(new Sub<int>(1))
    let b: string = to_g(new G<int>(2))
}
