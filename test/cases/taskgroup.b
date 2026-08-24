// TaskGroup<T> (spec/CONCURRENCY.md, F3): a scope-bound fleet of brewed
// fibers when the count is a runtime value. group.brew(f(x)) starts a
// child exactly as `brew` does; next() parks for the earliest unclaimed
// completion and answers some(ok(v)) / some(err(e)) / none; wait_all()
// joins the rest in spawn order; the group is empty and reusable after.
// A panicked child surfaces as err at delivery instead of ending the
// program. One worker, one scheduler: both engines must print identical
// bytes, delivery order included.
import std.io
import std.time as time

fn quick(n: int) -> int { return n * 10 }

fn slow(n: int) -> int {
    time.sleep_millis(20)
    return n * 100
}

fn moody(n: int) -> int {
    if n == 2 { panic("moody child {n}") }
    return n
}

fn label(outcome: Option<Result<int>>) -> string {
    match outcome {
        some(result) => {
            match result {
                ok(value) => { return "ok {value}" }
                err(error) => { return "err {error.kind}: {error.msg}" }
            }
        }
        none => { return "none" }
    }
}

fn main() {
    // completion order beats spawn order: the slow child spawned first
    // finishes last
    let group: TaskGroup<int> = new TaskGroup<int>()
    group.brew(slow(1))
    group.brew(quick(2))
    group.brew(quick(3))
    io.println("first {label(group.next())}")
    io.println("second {label(group.next())}")
    io.println("third {label(group.next())}")
    io.println("drained {label(group.next())}")

    // reusable after draining; wait_all answers spawn order, not
    // completion order
    group.brew(slow(4))
    group.brew(quick(5))
    match group.wait_all() {
        ok(values) => {
            for value: int in values { io.println("waited {value}") }
        }
        err(error) => { io.println("wait failed {error.kind}") }
    }

    // a panicked child is an err at delivery, and the program stands
    let risky: TaskGroup<int> = new TaskGroup<int>()
    risky.brew(moody(1))
    risky.brew(moody(2))
    risky.brew(moody(3))
    match risky.wait_all() {
        ok(values) => { io.println("unexpected calm") }
        err(error) => { io.println("fleet failed {error.kind}: {error.msg}") }
    }

    // try_next answers immediately; cancel_all discards a fleet
    let idle: TaskGroup<int> = new TaskGroup<int>()
    idle.brew(slow(6))
    io.println("early {label(idle.try_next())}")
    idle.cancel_all()
    io.println("cancelled {label(idle.try_next())}")
    io.println("done")
}
