// #162, the other half: what a static on a generic type still cannot do, and
// where each refusal is written.
//
// An owner type parameter a static's signature names is promoted to the
// static's own and bound at the call. One that only the *body* names has
// nothing to bind it — no argument carries it, the result does not mention it,
// and a static has no receiver — so every instantiation would still hold a
// bare `T`. That shape used to check clean, run in the interpreter (printing
// the literal string "T" for `type_of(T)`) and die in a native build with
// "LLVM emitter cannot form class layout 'main.Holder<T>'". It is refused at
// the declaration now, in the program's own words.
//
// The call-site refusals below are the ones a promoted parameter inherits from
// the generic machinery it now goes through: an unbindable result, a bound the
// owner declared, and explicit type arguments that are too many or that fight
// the argument.
package main

import std.io
import std.reflect

pub class Holder<T> {
    pub value: Option<T> = none

    pub fn init() {}

    pub static fn wrap(value: T) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = some(value)
        return held
    }

    pub static fn empty() -> Holder<T> { return new Holder<T>() }

    // T only in the body: a local's declared type
    pub static fn count() -> int {
        let held: Holder<T> = new Holder<T>()
        return 1
    }

    // T only in the body, reached through a closure's type
    pub static fn size() -> int {
        let make: fn() -> List<T> = fn() -> List<T> { return [] }
        return make().len()
    }

    // T only in the body, reached through reflection — this one used to
    // print the literal "T" on both backends
    pub static fn describe() -> string {
        return type_of(T).qualified_name()
    }
}

pub class Bare {
    pub fn init() {}
}

// the owner's bound travels to the call with the parameter it constrains
pub class Sorted<K implements Order> {
    pub key: Option<K> = none

    pub fn init() {}

    pub static fn between(low: K, high: K) -> bool { return low < high }
}

fn main() {
    // nothing types this call, so the result cannot bind T either
    let unbound: bool = Holder.empty().value.is_some()

    // a promoted parameter still has to satisfy the owner's bound
    let ordered: bool = Sorted.between(new Bare(), new Bare())

    // one type argument too many
    let too_many: Holder<int> = Holder.empty<int, string>()

    // an explicit binding the argument contradicts
    let fighting: Holder<string> = Holder.wrap<string>(3)

    io.println("{unbound} {ordered} {too_many.value.is_some()} {fighting.value.is_some()}")
}
