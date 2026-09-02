// A panic that reaches the entry of a spawned thread ends the process, on
// both backends (issue #75, spec/CONCURRENCY.md). Thread<T>.join() answers T,
// not Result<T>, so a thread's failure has no value-shaped place to land, and
// a detached or never-joined thread has no join at all — the interpreter used
// to stash the panic and re-raise it at join, which armed no unwind, skipped
// the joining fiber's defers, and dropped the failure entirely when no one
// joined. `brew` is the contained form; a thread is the raw primitive.
//
// One mode per argument, because a program can only die once. The last two
// modes are the other half of the claim: a thread that returns normally still
// delivers its value, and a panic the thread itself contains with brew/join
// stays contained — the process must survive both.
import std.io
import std.os
import std.thread
import std.time

class Loud {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  deinit {self.tag}") }
}

fn boom() -> int {
    let empty: List<int> = []
    return empty[0]
}

// Frames of the thread's own stack, with a defer and an owned local: an
// uncontained panic abandons them on both backends, exactly as it does on
// the main fiber.
fn inside_thread() -> int {
    let held: Loud = new Loud("thread-held")
    defer io.println("  thread defer")
    return boom()
}

fn contained_in_thread() -> int {
    let child: Brew<int> = brew inside_thread()
    match child.join() {
        ok(v) => { return v }
        err(problem) => { return -1 }
    }
}

// The joining side owns a defer and a local too. A re-raise at join used to
// set the panic flag without arming an unwind, so neither ever ran.
fn joiner() -> int {
    let held: Loud = new Loud("joiner-held")
    defer io.println("  joiner defer")
    let worker: Thread<int> = thread.spawn(fn() -> int { return inside_thread() })
    return worker.join()
}

// joined from inside a brewed fiber: the thread's panic is not the fiber's,
// so brew does not contain it.
fn shielded_join() -> string {
    let child: Brew<int> = brew joiner()
    match child.join() {
        ok(v) => { return "ok {v}" }
        err(problem) => { return "contained: {problem.kind}" }
    }
}

fn mode() -> string {
    let given: List<string> = os.args()
    if given.len() == 0 { return "join" }
    return given[0]
}

fn main() {
    let which: string = mode()
    io.println("mode {which}")
    if which == "join" {
        // joined from the root fiber
        let worker: Thread<int> = thread.spawn(fn() -> int { return inside_thread() })
        io.println("joined {worker.join()}")
        io.println("unreachable")
    } else if which == "brew" {
        io.println(shielded_join())
        io.println("unreachable")
    } else if which == "unjoined" {
        let worker: Thread<int> = thread.spawn(fn() -> int { return inside_thread() })
        time.sleep_millis(400)
        io.println("unreachable")
    } else if which == "detached" {
        let worker: Thread<int> = thread.spawn(fn() -> int { return inside_thread() })
        worker.detach()
        time.sleep_millis(400)
        io.println("unreachable")
    } else if which == "value" {
        // the happy path still delivers
        let worker: Thread<int> = thread.spawn(fn() -> int { return 7 })
        io.println("value {worker.join()}")
    } else {
        // the thread contains its own panic with brew: the process stands
        let worker: Thread<int> = thread.spawn(fn() -> int { return contained_in_thread() })
        io.println("contained in thread {worker.join()}")
    }
    io.println("end")
}
