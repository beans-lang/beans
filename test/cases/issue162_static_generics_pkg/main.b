// The calls. Every one of these binds a type parameter the *class* declared,
// on a receiver named through a package — plain, aliased, and with the type
// arguments written out. `T` is bound to a builtin and to a class declared in
// this package, which the declaring package has never seen.
package main

import std.io
import app.box
import app.box as bx

pub class Label {
    pub text: string = ""

    pub fn init(text: string) { self.text = text }
}

fn held_count(held: box.Holder<string>) -> int {
    if held.value.is_some() { return 1 }
    return 0
}

fn main() {
    // inferred from the argument, through the package name
    let a: box.Holder<int> = box.Holder.wrap(3)
    let b: box.Holder<string> = box.Holder.wrap("w")
    io.println("{a.value.expect("a")} {b.value.expect("b")}")

    // inferred from the expected result alone, with nothing else to read it off
    let c: box.Holder<int> = box.Holder.empty()
    io.println("{c.value.is_some()} {held_count(box.Holder.empty())}")

    // through an import alias
    let d: bx.Holder<string> = bx.Holder.wrap("alias")
    io.println("{d.value.expect("d")}")

    // written out, on a static whose only type parameter is the class's
    let e: box.Holder<int> = box.Holder.wrap<int>(5)
    let f: box.Holder<string> = box.Holder.empty<string>()
    io.println("{e.value.expect("e")} {f.value.is_some()}")

    // T nested in the result, and the class's parameter beside the method's own
    let paired: List<int> = box.Holder.pair(7, 8)
    let g: box.Holder<int> = box.Holder.labelled(9, "note")
    let h: box.Holder<int> = box.Holder.labelled<int, string>(10, "note")
    io.println("{paired[1]} {g.value.expect("g")} {h.value.expect("h")}")

    // T bound to a class this package declares and the other one cannot see
    let labelled: box.Holder<Label> = box.Holder.wrap(new Label("lab"))
    io.println("{labelled.value.expect("l").text}")

    // the owner's bound, measured across the boundary
    io.println("{box.Sorted.between(2, 9)} {box.Sorted.between("y", "b")}")
}
