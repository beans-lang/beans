// Reflection resolves a method against the receiver's runtime class, and it
// has to reach the same body an ordinary call would. Both backends matched
// the runtime class's entry by name alone, so a `static fn` wearing the name
// of an inherited instance method was substituted and then invoked with the
// receiver — handed to a function that declares no parameter for it (#88).
//
// The checker refuses that pair wherever a call could name it. `priv` is
// exempt there on purpose: a private method belongs to its exact declaring
// type, is never inherited and shares no dispatch slot, so a subclass writing
// the same name is already a separate method. That exemption is what left
// this door open, so the case is built on exactly that shape.
package main

import std.io
import std.reflect

class Ledger {
    fn init() {}

    pub fn stamp() -> string { return "Ledger.stamp" }

    pub fn note() -> string { return "Ledger.note" }
}

class SubLedger extends Ledger {
    fn init() { super.init() }

    // a real override, which reflection must still prefer
    pub override fn note() -> string { return "SubLedger.note" }

    // and a `priv static` wearing the inherited name, which it must not
    priv static fn stamp() -> string {
        return "SubLedger.stamp/static"
    }

    fn own() -> string { return SubLedger.stamp() }
}

// two links down, so the walk that finds the runtime class's entry has more
// than one step to take
class DeepLedger extends SubLedger {
    fn init() { super.init() }
}

// `SubLedger` wears `stamp` on a `priv static`, so inside that class the
// nearest declaration of the name is one no receiver can pick and
// `sub.stamp()` is refused there. A base-typed reference still reaches the
// instance method, which is the answer reflection has to agree with.
fn stamp(value: Ledger) -> string { return value.stamp() }

fn note(value: Ledger) -> string { return value.note() }

fn reflect_call(receiver: reflect.Value, name: string) -> string {
    let found: reflect.Method =
        type_of(Ledger).method(name).expect("Ledger method")
    match found.call(receiver, []) {
        ok(answer) => {
            return (answer as? string).expect("string answer")
        }
        err(problem) => { return "err {problem.kind()}" }
    }
}

fn main() {
    // the plain calls, for the answers reflection has to match
    io.println(stamp(new SubLedger()))
    io.println(note(new SubLedger()))
    io.println(stamp(new DeepLedger()))
    io.println(note(new DeepLedger()))
    io.println(new SubLedger().own())

    let one: SubLedger = new SubLedger()
    io.println(reflect_call(reflect.value(move one), "stamp"))
    let two: SubLedger = new SubLedger()
    io.println(reflect_call(reflect.value(move two), "note"))

    let deep: DeepLedger = new DeepLedger()
    io.println(reflect_call(reflect.value(move deep), "stamp"))
    let deep_note: DeepLedger = new DeepLedger()
    io.println(reflect_call(reflect.value(move deep_note), "note"))

    // and the base itself, which was never in doubt
    let base: Ledger = new Ledger()
    io.println(reflect_call(reflect.value(move base), "stamp"))
}
