// A catch frame works on any fiber of any thread (issue #145).
//
// A spawned thread is not a fiber, and containment has never reached one: a
// panic at a thread's entry ends the process, because Thread<T>.join() answers
// T and has no join-shaped place to put a failure (spec/CONCURRENCY.md). A
// `contained` call changes that where it stands, and only there — the boundary
// is the call, so it does not need a join to deliver to. The first entry on a
// thread promotes it to a worker so the count has a fiber to live on, which is
// what makes this work at all.
//
// The TaskGroup case is the fleet flavour of the same thing: a child's own
// catch frame answers before the group's delivery does.
import std.io
import std.thread

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

fn refuses(tag: string) -> int {
    let r: Res = new Res(tag)
    panic("{tag} refused")
}

fn works(n: int) -> int { return n * 3 }

// The thread legs print nothing on the way out: two threads unwinding at once
// interleave, and a golden cannot pin an interleaving. That the buffer is
// released is the sanitize gate's job; what this case proves is that the
// boundary answers at all off the main worker.
fn refuses_quietly(n: int) -> int {
    let held: List<int> = [n, n + 1]
    panic("quiet {n}")
}

// Runs on a spawned thread, off the process's main worker entirely.
fn on_a_thread(n: int) -> int {
    var caught: int = 0
    match contained refuses_quietly(n) {
        ok(v) => { caught = -1 }
        err(p) => { caught = 1 }
    }
    match contained works(n) {
        ok(v) => { return caught * 100 + v }
        err(p) => { return -1 }
    }
}

fn in_a_group(n: int) -> int {
    match contained refuses("group-{n}") {
        ok(v) => { return -1 }
        err(p) => { return n }
    }
}

fn threads() {
    io.println("on spawned threads:")
    let a: Thread<int> = thread.spawn(fn() -> int { return on_a_thread(1) })
    let b: Thread<int> = thread.spawn(fn() -> int { return on_a_thread(2) })
    let first: int = a.join()
    let second: int = b.join()
    io.println("  joined {first} and {second}")
}

fn groups() {
    io.println("in a task group:")
    let fleet: TaskGroup<int> = new TaskGroup<int>()
    var total: int = 0
    for n: int in 1..4 {
        fleet.brew(in_a_group(n))
    }
    match fleet.wait_all() {
        ok(values) => {
            for v: int in values { total += v }
        }
        err(p) => { total -= 100 }
    }
    io.println("  total {total}")
}

fn main() {
    threads()
    groups()
    io.println("done")
}
