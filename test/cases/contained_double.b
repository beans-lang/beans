// A panic inside a defer that a contained unwind is running is the one
// unrecoverable case (spec/CONCURRENCY.md), exactly as it is for a brewed
// fiber's unwind: there is no second unwind to give it, so both reports go out
// and the process stops. A catch frame does not change that — the runtime
// asks "is this fiber already unwinding" before it asks anything else, and the
// tree walker's fail_with_text asks the same question in the same order.
import std.io

fn dies_during_cleanup() {
    panic("the defer failed too")
}

fn fails_with_a_failing_defer() -> int {
    defer dies_during_cleanup()
    panic("the call failed")
}

fn main() {
    io.println("before")
    match contained fails_with_a_failing_defer() {
        ok(v) => { io.println("unexpected ok {v}") }
        err(p) => { io.println("unexpected catch {p.kind}") }
    }
    io.println("unreachable")
}
