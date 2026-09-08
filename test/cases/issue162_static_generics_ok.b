// #162: a static method on a generic type binds its owner's type parameters.
//
// A static has no receiver, so nothing at the call site used to bind the
// class's `T`: `Holder.wrap(3)` answered `expected T, got int` and
// `Holder.empty()` answered `expected Holder<int>, got Holder<T>`, which left
// the declaration reachable from nowhere. The owner parameters a static's own
// signature names are now its own type parameters, inferred from the arguments
// and from the expected result and bindable outright with `Holder.wrap<int>(3)`.
//
// Every line here is printed by the interpreter, a debug build and a release
// build, and the golden file locks all three to the same bytes.
package main

import std.io
import std.reflect

pub class Holder<T> {
    pub value: Option<T> = none

    pub fn init() {}

    // T in an argument and in the result
    pub static fn wrap(value: T) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = some(value)
        return held
    }

    // T in the result only: the declared type of the binding drives it
    pub static fn empty() -> Holder<T> { return new Holder<T>() }

    // one static calling another of the same class, with T still open
    pub static fn wrap_via_empty(value: T) -> Holder<T> {
        let held: Holder<T> = Holder.empty()
        held.value = some(value)
        return held
    }

    // T nested inside another generic, both ways
    pub static fn first(items: List<T>) -> Option<T> {
        if items.len() == 0 { return none }
        return some(items[0])
    }

    pub static fn pair(left: T, right: T) -> List<T> {
        return [left, right]
    }

    pub static fn of_option(value: Option<T>) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = value
        return held
    }

    // the class's T beside the method's own U, in source order:
    // `both<int, string>` binds T then U
    pub static fn both<U>(value: T, note: U) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = some(value)
        return held
    }

    // a promoted T reaches reflection like any other bound parameter
    pub static fn describe(value: T) -> string {
        return type_of(T).qualified_name()
    }

    // recursion through the static's own promoted parameter
    pub static fn repeat(value: T, times: int) -> List<T> {
        if times <= 0 { return [] }
        var rest: List<T> = Holder.repeat(value, times - 1)
        rest.push(value)
        return move rest
    }

    // a static that names no type parameter at all still needs none
    pub static fn tag() -> string { return "holder" }

    // the method's own <T> shadows the class's, so the class's is NOT
    // promoted and this still takes exactly one type argument — two would be
    // the failure if the shadow check went away
    pub static fn echo<T>(value: T) -> T { return value }

    // visibility does not change the rule: a priv static binds its owner's
    // parameter the same way, reached from a pub one of the same class
    priv static fn hidden(value: T) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = some(value)
        return held
    }

    pub static fn via_hidden(value: T) -> Holder<T> {
        return Holder.hidden(value)
    }

    // an instance method calling its own class's static: T here is the
    // receiver's T, still open, and the call must bind it to that
    pub fn twin() -> Holder<T> {
        return Holder.wrap(self.value.expect("twin"))
    }
}

// two owner parameters, a static that names only the second
pub class Cell<K, V> {
    pub key: Option<K> = none
    pub item: Option<V> = none

    pub fn init() {}

    pub static fn only_value(value: V) -> Cell<int, V> {
        let cell: Cell<int, V> = new Cell<int, V>()
        cell.item = some(value)
        return cell
    }

    // the method shadows the owner's first parameter and names its second, so
    // only V is promoted and the written order is <V, K> — the promoted ones
    // in the owner's order, then the method's own. Promoting a shadowed name
    // as well would make this `<K, V, K>`, a list with one name twice, and
    // `Cell.odd<int, string>` would then answer "generic V was string, then
    // int".
    pub static fn odd<K>(key: K, value: V) -> V { return value }
}

// a bound on the owner's parameter travels with it to the call
pub class Sorted<K implements Order> {
    pub key: Option<K> = none

    pub fn init() {}

    pub static fn between(low: K, high: K) -> bool { return low < high }
}

// a generic struct's static factory
pub struct Twin<T> {
    left: T
    right: T

    pub static fn of(value: T) -> Twin<T> {
        return Twin { left: value, right: value }
    }
}

// a generic enum's static
pub enum Maybe<T> {
    nothing
    something

    pub static fn empty_of() -> Maybe<T> { return Maybe.nothing }
    pub static fn full_of() -> Maybe<T> { return Maybe.something }
}

// a `partial class` — the declaration form the compiler's own sources are
// written in, and the only one whose members are lowered from more than one
// AST node
pub partial class Boxed<T> {
    pub value: Option<T> = none

    pub fn init() {}

    pub static fn of(value: T) -> Boxed<T> {
        let boxed: Boxed<T> = new Boxed<T>()
        boxed.value = some(value)
        return boxed
    }
}

pub class Label {
    pub text: string = ""

    pub fn init(text: string) { self.text = text }
}

fn make_int_holder() -> Holder<int> { return Holder.empty() }

fn count_strings(held: Holder<string>) -> int {
    if held.value.is_some() { return 1 }
    return 0
}

fn main() {
    // inferred from the argument, at two instantiations
    let a: Holder<int> = Holder.wrap(3)
    let b: Holder<string> = Holder.wrap("x")
    let av: int = a.value.expect("a")
    let bv: string = b.value.expect("b")
    io.println("{av} {bv}")

    // inferred from the declared type of the binding, with nothing to read
    // it off but the result
    let c: Holder<int> = Holder.empty()
    let d: Holder<string> = Holder.empty()
    io.println("{c.value.is_some()} {d.value.is_some()}")

    // the same inference at a return and at an argument
    let e: Holder<int> = make_int_holder()
    io.println("{e.value.is_some()} {count_strings(Holder.empty())}")

    // one static through another
    let f: Holder<int> = Holder.wrap_via_empty(11)
    let fv: int = f.value.expect("f")
    io.println("{fv}")

    // T nested in List and in Option
    let ints: List<int> = [4, 5, 6]
    let words: List<string> = ["p", "q"]
    let first_int: int = Holder.first(ints).expect("first int")
    let first_word: string = Holder.first(words).expect("first word")
    io.println("{first_int} {first_word}")

    let paired: List<int> = Holder.pair(7, 8)
    let paired_words: List<string> = Holder.pair("r", "s")
    io.println("{paired.len()} {paired[1]} {paired_words[0]}")

    let g: Holder<int> = Holder.of_option(some(12))
    let gv: int = g.value.expect("g")
    io.println("{gv}")

    // the class's parameter and the method's own, inferred together
    let h: Holder<int> = Holder.both(13, "note")
    let hv: int = h.value.expect("h")
    io.println("{hv}")

    // and written out: the class's parameter first, then the method's own
    let i: Holder<int> = Holder.both<int, string>(14, "note")
    let iv: int = i.value.expect("i")
    io.println("{iv}")

    // explicit type arguments on a static whose only parameter is the
    // class's — the spelling that used to answer "does not take explicit
    // type arguments"
    let j: Holder<int> = Holder.wrap<int>(15)
    let k: Holder<string> = Holder.empty<string>()
    let jv: int = j.value.expect("j")
    io.println("{jv} {k.value.is_some()}")

    // reflection sees what the call bound
    let named_int: string = Holder.describe(1)
    let named_word: string = Holder.describe("z")
    io.println("{named_int} {named_word}")

    // recursion through the promoted parameter
    let repeated: List<string> = Holder.repeat("t", 3)
    io.println("{repeated.len()} {repeated[2]}")

    // a static that names no parameter is unaffected
    io.println(Holder.tag())

    // an instance method calling its own class's static
    let twinned: Holder<int> = a.twin()
    let tv: int = twinned.value.expect("twin")
    io.println("{tv}")

    // two owner parameters, only the second named by the static
    let cell: Cell<int, string> = Cell.only_value("cellv")
    let cv: string = cell.item.expect("cell")
    io.println("{cv}")

    // one owner parameter promoted past a shadowed one: <V, K>, written and
    // inferred
    let odd_written: int = Cell.odd<int, string>("k", 7)
    let odd_inferred: string = Cell.odd(1, "v")
    io.println("{odd_written} {odd_inferred}")

    // the owner's bound is measured against what the call bound
    let numbers_rise: bool = Sorted.between(2, 9)
    let words_rise: bool = Sorted.between("y", "b")
    io.println("{numbers_rise} {words_rise}")

    // a struct's static factory
    let twin_int: Twin<int> = Twin.of(21)
    let twin_word: Twin<string> = Twin.of("w")
    io.println("{twin_int.left}{twin_int.right} {twin_word.left}")

    // a generic enum's static
    let maybe_int: Maybe<int> = Maybe.empty_of()
    let maybe_word: Maybe<string> = Maybe.full_of()
    io.println("{maybe_int == Maybe.nothing} {maybe_word == Maybe.nothing}")

    // the method's own <T> shadows the class's: one type argument, not two
    io.println("{Holder.echo<int>(41)} {Holder.echo("ec")}")

    // a priv static naming the class's T, reached from a pub one
    let hidden: Holder<int> = Holder.via_hidden(42)
    io.println("{hidden.value.expect("hidden")}")

    // a partial class's static
    let boxed_int: Boxed<int> = Boxed.of(31)
    let boxed_word: Boxed<string> = Boxed.of("bx")
    io.println("{boxed_int.value.expect("bi")} {boxed_word.value.expect("bw")}")

    // T bound to a class reference, and to a generic instantiation
    let labelled: Holder<Label> = Holder.wrap(new Label("lab"))
    let label: Label = labelled.value.expect("label")
    let nested: Holder<Holder<int>> = Holder.wrap(a)
    let inner: Holder<int> = nested.value.expect("nested")
    let innerv: int = inner.value.expect("inner")
    io.println("{label.text} {innerv}")
}
