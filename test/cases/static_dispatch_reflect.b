// A method the emitter calls directly is still a row in its class's
// descriptor, and reflection reads exactly those rows. Every method here is
// one the static-dispatch rule settles — a leaf class, an inherited body
// nobody replaces, an abstract class with a single concrete subclass, a sole
// interface implementor — so if settling a call ever cost a table row, these
// reflective calls would be the ones to lose their target.
package main

import std.io
import std.reflect

class Solo {
    pub fn init() {}

    pub fn name() -> string { return "Solo.name" }
}

class Root {
    pub fn init() {}

    pub fn kind() -> string { return "Root.kind" }
}

class Mid extends Root {
    pub fn init() { super.init() }
}

class Leaf extends Mid {
    pub fn init() { super.init() }
}

abstract class Task {
    pub abstract fn run() -> string

    pub fn go() -> string { return "go/{self.run()}" }
}

class OnlyTask extends Task {
    pub fn init() {}

    pub override fn run() -> string { return "OnlyTask.run" }
}

interface Only {
    fn once() -> string
}

class TheOnly implements Only {
    pub fn init() {}

    pub fn once() -> string { return "TheOnly.once" }
}

// the same calls the direct way, so the golden pins both halves
fn direct_solo(value: Solo) -> string { return value.name() }

fn direct_leaf(value: Leaf) -> string { return value.kind() }

fn direct_task(value: Task) -> string { return value.go() }

fn direct_only(value: Only) -> string { return value.once() }

fn reflect_call(type_name: reflect.Type, method: string,
                receiver: reflect.Value) -> string {
    let found: reflect.Method =
        type_name.method(method).expect(method)
    let answer: reflect.Value =
        found.call(receiver, []).expect(method)
    return (answer as? string).expect(method)
}

fn main() {
    io.println(direct_solo(new Solo()))
    io.println(direct_leaf(new Leaf()))
    io.println(direct_task(new OnlyTask()))
    io.println(direct_only(new TheOnly()))

    io.println(
        reflect_call(
            type_of(Solo), "name",
            reflect.value(new Solo())))
    // declared on Root, asked for on a Leaf: the row the subclass inherits
    io.println(
        reflect_call(
            type_of(Root), "kind",
            reflect.value(new Leaf())))
    io.println(
        reflect_call(
            type_of(Leaf), "kind",
            reflect.value(new Leaf())))
    // the abstract class's own body, and the row only the subclass fills
    io.println(
        reflect_call(
            type_of(Task), "go",
            reflect.value(new OnlyTask())))
    io.println(
        reflect_call(
            type_of(OnlyTask), "run",
            reflect.value(new OnlyTask())))
    io.println(
        reflect_call(
            type_of(TheOnly), "once",
            reflect.value(new TheOnly())))
}
