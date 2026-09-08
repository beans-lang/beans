// Issue #161: a generic whose type parameter appears inside a function-typed
// parameter. `fn(T)` written without `-> unit` is the same type as
// `fn(T) -> unit` — hir_type_key renders both the same way — but only the
// second carries the result in `args`, and a closure literal always carries
// it. The two places that matched function types read the raw `args` list, so
// an annotation's `fn(T)` never lined up with a literal's `fn(Hint) -> unit`:
// the checker inferred nothing across the mismatch, and the native emitter
// refused the call talking about itself while the interpreter ran it.
//
// Every section below is at least two instantiations wide, and every closure
// is actually invoked with a value of the bound type: an instance keyed or
// substituted wrong shows up as a wrong count or a wrong string, not just as
// a build that happens to succeed.
package main

import std.io

pub class Hint {
    pub label: string = "-"
    pub fn init() {}
}

pub class Base {
    pub tag: string
    pub fn init(tag: string) { self.tag = tag }
}

pub class Derived extends Base {
    pub fn init() { super.init("derived") }
}

// A — the reported shape: a free function taking `fn(T)`, with the result
// left unwritten. The body calls the closure `rounds` times.
pub fn drive<T>(rounds: int, value: T, setup: fn(T)) -> int {
    var index: int = 0
    for index < rounds {
        setup(value)
        index += 1
    }
    return rounds
}

// B — the mirror: the parameter spells `-> unit`, the argument may not.
pub fn drive_spelled<T>(rounds: int, value: T,
                        setup: fn(T) -> unit) -> int {
    var index: int = 0
    for index < rounds {
        setup(value)
        index += 1
    }
    return rounds
}

// C — T in the function type's result, and in the value it returns.
pub fn fold<T>(value: T, step: fn(T) -> T, rounds: int) -> T {
    var carried: T = value
    var index: int = 0
    for index < rounds {
        carried = step(carried)
        index += 1
    }
    return carried
}

// D — a function type nested inside a function type.
pub fn nested<T>(outer: fn(fn(T))) -> string {
    return "nested"
}

// E — a function type in the result.
pub fn make_setter<T>(seed: T) -> fn(T) {
    return fn(x: T) {}
}

// F — function types inside composites.
pub fn from_list<T>(setups: List<fn(T)>, value: T) -> int {
    for setup: fn(T) in setups {
        setup(value)
    }
    return setups.len()
}

pub fn from_option<T>(setup: Option<fn(T)>, value: T) -> string {
    match setup {
        some(found) => {
            found(value)
            return "some"
        }
        none => { return "none" }
    }
}

// G — two type parameters, only one of them inside the function type.
pub fn pair_apply<A, B>(left: A, value: B, setup: fn(B)) -> string {
    setup(value)
    return "pair"
}

// H — a sendable function type.
pub fn take_send<T>(value: T, setup: send fn(T)) -> string {
    setup(value)
    return "send"
}

// I — a generic calling a generic, forwarding its own T: the instance an
// instance begets.
pub fn twice<T>(value: T, setup: fn(T)) -> int {
    return drive<T>(2, value, setup)
}

// J — T only in the function type's result, nowhere else in the signature.
pub fn produce<T>(make: fn() -> T) -> string {
    return "produced"
}

// K — a generic free function with an ordinary class parameter, called with
// a subclass. Unification lines nothing up here, and that was refused too.
pub fn labelled<T>(value: T, at: Base) -> string {
    return "{at.tag}"
}

// M — a type parameter that shadows a class name. Which names are type
// variables is the template's own business: resolving the name instead finds
// the class, so the parameter read as a concrete type, matched nothing, and
// the call was refused at build time on a program the checker took.
pub fn shadow_wrap<Hint>(value: Hint) -> List<Hint> {
    return [value]
}

pub fn shadow_apply<Hint>(value: Hint, setup: fn(Hint)) -> int {
    setup(value)
    return 1
}

pub class Shadow {
    pub fn init() {}
    pub static fn stat<Hint>(value: Hint,
                             setup: fn(Hint)) -> int {
        setup(value)
        return 2
    }
}

pub class Host {
    pub fn init() {}
    // an instance method: the route that already emitted
    pub fn apply<T>(rounds: int, value: T, setup: fn(T)) -> int {
        var index: int = 0
        for index < rounds {
            setup(value)
            index += 1
        }
        return rounds
    }
    // a static: the route that did not
    pub static fn stat_apply<T>(rounds: int, value: T,
                                setup: fn(T)) -> int {
        var index: int = 0
        for index < rounds {
            setup(value)
            index += 1
        }
        return rounds
    }
}

pub class Holder<T> {
    pub held: T
    pub fn init(held: T) { self.held = held }
    // a generic class's method with a type parameter of its own
    pub fn apply<U>(rounds: int, value: U, setup: fn(U)) -> int {
        var index: int = 0
        for index < rounds {
            setup(value)
            index += 1
        }
        return rounds
    }
    // a static of a generic class, reached through the bare class name
    pub static fn stat_apply<U>(value: U, setup: fn(U)) -> string {
        setup(value)
        return "holder-static"
    }
}

fn stamp(x: Hint) { x.label = "{x.label}n" }

fn main() {
    // A — the reported shape, at two arguments, closure invoked each round
    let h: Hint = new Hint()
    var seen: int = 0
    io.println("A {drive<Hint>(3, h, fn(x: Hint) { x.label = "{x.label}a" })}")
    io.println("A {drive<int>(4, 7, fn(v: int) { seen += v })}")
    io.println("A {h.label} {seen}")

    // A — the same call written without an explicit type argument. The
    // checker used to refuse this one on its own, with "expected fn(T) ->
    // unit, got fn(main.Hint) -> unit".
    io.println("A {drive(2, h, fn(x: Hint) { x.label = "{x.label}b" })}")
    io.println("A {h.label}")

    // A — a named function as the argument rather than a closure literal
    io.println("A {drive<Hint>(2, h, stamp)}")
    io.println("A {h.label}")

    // A — and through a variable, the spelling that always worked
    let via: fn(Hint) = fn(x: Hint) { x.label = "{x.label}v" }
    io.println("A {drive<Hint>(1, h, via)} {h.label}")

    // B — parameter spells the result, argument does not, and the reverse
    io.println("B {drive_spelled<Hint>(2, h, via)}")
    io.println("B {drive_spelled<Hint>(1, h, fn(x: Hint) { x.label = "{x.label}s" })}")
    io.println("B {h.label}")

    // C — T in the function type's result
    io.println("C {fold<int>(1, fn(v: int) -> int { return v * 3 }, 3)}")
    io.println("C {fold<string>("x", fn(v: string) -> string { return "{v}y" }, 2)}")

    // D — a function type inside a function type
    io.println("D {nested<Hint>(fn(inner: fn(Hint)) {})} {nested<int>(fn(inner: fn(int)) {})}")

    // E — a function type as the result
    let made: fn(Hint) = make_setter<Hint>(h)
    let made_int: fn(int) = make_setter<int>(2)
    io.println("E {drive<Hint>(1, h, made)} {drive<int>(1, 5, made_int)}")

    // F — function types inside composites
    var count: int = 0
    let setups: List<fn(int)> = [
        fn(v: int) { count += v },
        fn(v: int) { count += v * 2 },
    ]
    io.println("F {from_list<int>(setups, 3)} {count}")
    io.println("F {from_option<int>(some(fn(v: int) { count += v }), 10)} {count}")
    let empty: Option<fn(int)> = none
    io.println("F {from_option<int>(empty, 1)} {count}")

    // G — two parameters, one of them in the function type
    io.println("G {pair_apply<int, Hint>(1, h, fn(x: Hint) { x.label = "{x.label}g" })}")
    io.println("G {pair_apply<string, int>("k", 4, fn(v: int) { count += v })} {count}")

    // H — a sendable function type
    io.println("H {take_send<int>(6, fn(v: int) {})} {take_send<string>("t", fn(v: string) {})}")

    // I — an instance begetting an instance
    io.println("I {twice<Hint>(h, fn(x: Hint) { x.label = "{x.label}i" })} {h.label}")

    // J — T only in the result of the function type, both spellings
    io.println("J {produce(fn() -> int { return 1 })}")
    let plain: fn() = fn() {}
    io.println("J {produce(plain)}")

    // K — a subclass where a plain class parameter is declared
    io.println("K {labelled<int>(1, new Derived())} {labelled<string>("s", new Base("base"))}")

    // L — the receiver forms: instance, static, generic class, and the
    // static of a generic class through the bare class name
    let host: Host = new Host()
    io.println("L {host.apply<Hint>(2, h, fn(x: Hint) { x.label = "{x.label}m" })}")
    io.println("L {Host.stat_apply<Hint>(2, h, fn(x: Hint) { x.label = "{x.label}t" })}")
    let holder: Holder<int> = new Holder<int>(9)
    io.println("L {holder.apply<Hint>(1, h, fn(x: Hint) { x.label = "{x.label}u" })} {holder.held}")
    io.println("L {Holder.stat_apply<Hint>(h, fn(x: Hint) { x.label = "{x.label}w" })}")
    io.println("L {h.label}")

    // M — a type parameter shadowing a class name, on every route, and one
    // of them with the shadowed name inside a function type as well
    let ws: List<int> = shadow_wrap(3)
    let wt: List<string> = shadow_wrap("t")
    io.println("M {ws.len()} {ws[0]} {wt[0]}")
    io.println("M {shadow_apply(4, fn(v: int) { count += v })} {count}")
    io.println("M {shadow_apply<string>("z", fn(v: string) {})}")
    io.println("M {Shadow.stat("y", fn(v: string) {})} {Shadow.stat<int>(1, fn(v: int) { count += v })} {count}")
}
