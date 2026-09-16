// Does the runtime this was linked against carry the controlled unwind?
// Without it a panicking fiber abandons its frames: neither line below prints.
import std.io

class Held {
    fn deinit() { io.println("the frame dropped what it held") }
}

fn risky() -> int {
    let held: Held = new Held()
    defer io.println("the frame ran its defer")
    panic("on purpose")
}

fn main() {
    let job: Brew<int> = brew risky()
    match job.join() {
        ok(value) => { io.println("unexpected ok {value}") }
        err(problem) => { io.println("the join caught it") }
    }
}
