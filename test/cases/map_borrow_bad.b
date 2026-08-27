// Every way to end up with two live readers of one move-only map value, and
// the two older refusals that keep such a value from leaving the map at all.
import std.io

unique class Slot {
    pub hits: int = 0
}

fn two_readers(store: Map<string, Bytes>) {
    match store.get("k") {
        some(first) => {
            match store.get("k") {
                some(second) => {
                    first.set(0, 66)
                    io.println("{first.get(0)} {second.get(0)}")
                }
                none => {}
            }
        }
        none => {}
    }
}

fn two_readers_deeper(store: Map<string, Bytes>) {
    match store.get("a") {
        some(first) => {
            if first.len() > 0 {
                match store.get("b") {
                    some(second) => {
                        io.println("{second.len()}")
                    }
                    none => {}
                }
            }
        }
        none => {}
    }
}

fn two_readers_class(slots: Map<string, Slot>) {
    match slots.get("s") {
        some(first) => {
            match slots.get("s") {
                some(second) => {
                    first.hits += 1
                    io.println("{second.hits}")
                }
                none => {}
            }
        }
        none => {}
    }
}

fn moved_out(store: Map<string, Bytes>) -> Option<Bytes> {
    match store.get("k") {
        some(held) => { return some(move held) }
        none => { return none }
    }
}

fn indexed(store: Map<string, Bytes>) {
    let copied: Bytes = store["k"]
    io.println("{copied.len()}")
}

fn main() {
    io.println("unreachable")
}
