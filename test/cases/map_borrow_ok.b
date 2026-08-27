// A move-only map value is handed back as the map's own, so the binding it
// lands in borrows the map. One borrow at a time is the rule; everything
// here stays inside it, and all of it has to keep working.
import std.io

unique class Slot {
    pub tag: string
    pub hits: int = 0
    fn init(tag: string) { self.tag = tag }
}

fn main() {
    var store: Map<string, Bytes> = {}
    store.set("a", Bytes.from("AAAA"))
    store.set("b", Bytes.from("BBBB"))

    // one at a time, in sequence
    match store.get("a") {
        some(first) => {
            first.set(0, 90)
            io.println("a is {first.to_string()}")
        }
        none => {}
    }
    match store.get("b") {
        some(second) => {
            second.set(3, 90)
            io.println("b is {second.to_string()}")
        }
        none => {}
    }

    // a read per key, inside a loop over the keys
    for key: string in store.keys() {
        match store.get(key) {
            some(value) => {
                value.push(33)
                io.println("{key} grew to {value.len()}")
            }
            none => {}
        }
    }

    // a second map is a second owner, so both may be read at once
    var other: Map<string, Bytes> = {}
    other.set("z", Bytes.from("ZZ"))
    match store.get("a") {
        some(left) => {
            match other.get("z") {
                some(right) => {
                    io.println("across maps {left.len()} {right.len()}")
                }
                none => {}
            }
        }
        none => {}
    }

    // a value type that is not move-only copies out, so nesting is fine
    var counts: Map<string, int> = {}
    counts.set("n", 7)
    match counts.get("n") {
        some(one) => {
            match counts.get("n") {
                some(two) => { io.println("counts {one} {two}") }
                none => {}
            }
        }
        none => {}
    }

    // a move-only class value behaves the same way as Bytes
    var slots: Map<string, Slot> = {}
    slots.set("s", new Slot("first"))
    match slots.get("s") {
        some(slot) => {
            slot.hits += 2
            io.println("slot {slot.tag} {slot.hits}")
        }
        none => {}
    }
    match slots.get("s") {
        some(slot) => { io.println("slot again {slot.hits}") }
        none => {}
    }

    // the borrow ends with its arm, so a later read of the same map is fine
    // even when the earlier binding shared its name
    match store.get("b") {
        some(again) => { io.println("b still {again.len()}") }
        none => {}
    }
    io.println("done")
}
