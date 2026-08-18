import std.io

fn matched_or_fallback(value: Option<string>,
                       fallback: bool) -> string {
    match value {
        some(item) => { return item }
        none => {}
    }
    if fallback {
        let item: string = "fallback"
        let read: fn() -> string =
            fn() -> string { return item }
        return read()
    }
    return "none"
}

fn weak_after_pattern() -> Weak<string> {
    let shared: Shared<string> =
        new Shared("pattern")
    let weak: Weak<string> =
        shared.downgrade()
    let optional: Option<Shared<string>> =
        some(shared)
    match optional {
        some(item) => { item.get() }
        none => {}
    }
    if false {
        let item: string = "shadow"
        let read: fn() -> string =
            fn() -> string { return item }
        read()
    }
    return weak
}

class Held {
    wrapped: fn() -> int

    pub fn init(wrapped: fn() -> int) {
        self.wrapped = wrapped
    }

    fn deinit() {
        io.println("drop held")
    }
}

fn main() {
    let fixed: int = 7
    let read_fixed: fn() -> int = fn() -> int { return fixed }

    var changed: int = 1
    let read_changed: fn() -> int = fn() -> int { return changed }
    changed = 9

    var mutated: int = 20
    let bump: fn() -> int = fn() -> int {
        mutated += 1
        return mutated
    }

    io.println("{read_fixed()} {read_changed()} {bump()} {bump()}")
    io.println(matched_or_fallback(some("matched"), false))
    io.println(matched_or_fallback(none, true))
    io.println("pattern weak {weak_after_pattern().is_expired()}")

    // an object whose field holds a closure made in this same frame
    // still runs its deinit at end of scope: the closure captures its
    // named bindings, not the frame that holds the object
    if true {
        let held: Held =
            new Held(fn() -> int { return fixed })
        let read: fn() -> int = held.wrapped
        io.println("held {read()}")
    }
    io.println("held gone")
}
