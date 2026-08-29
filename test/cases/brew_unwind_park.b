// A fiber's unwind is a fact about that fiber alone (issue #44, B3). A parent
// parked inside its cleanup — a defer that joins a child — lets other fibers
// run, finish and panic while it waits; none of that may touch the parent's
// own unwind, or the rest of its cleanup is silently skipped. The native
// runtime keeps the unwind in the BeansFiber; the interpreter once kept it in
// one process-wide field that a finishing child restored to the value it saw
// when it started — a child that started before the parent's panic restored
// "not unwinding", and the parent's older defer and its local's deinit never
// ran. Both backends must print the same lines, in the same order.
import std.io
import std.time

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

fn quick() -> int { return 0 }

// starts, parks on a sleep, and finishes later — while the parent is parked
// in its cleanup
fn napper(label: string) -> int {
    io.println("  {label} starts")
    time.sleep_millis(20)
    io.println("  {label} done")
    return 1
}

// the same, but panics after its sleep: a contained panic on a sibling
// fiber while the parent is parked in its cleanup
fn napper_panics(label: string) -> int {
    io.println("  {label} starts")
    time.sleep_millis(20)
    io.println("  {label} panics")
    let empty: List<int> = []
    return empty[5]
}

fn report(outcome: Result<int>) {
    match outcome {
        ok(v) => { io.println("  joined child {v}") }
        err(problem) => { io.println("  joined child: {problem.kind}") }
    }
}

// The child is brewed first and the parent parks on a quick sibling, so the
// child runs — and goes to sleep — before the parent panics. The parent then
// panics holding a local and two defers; the newest defer joins the sleeping
// child. The child finishes during that park. The older defer and the local's
// deinit must still run, and the join above must report the parent's panic.
fn parent_child_finishes() -> int {
    let child: Brew<int> = brew napper("nap")
    let sibling: Brew<int> = brew quick()
    match sibling.join() {
        ok(v) => {}
        err(problem) => { io.println("  unexpected: {problem.kind}") }
    }
    let held: Res = new Res("parent-held")
    defer io.println("  parent older defer")
    defer report(child.join())
    let empty: List<int> = []
    return empty[1]
}

// The same, with the child panicking (contained) while the parent is parked
// in its cleanup: the sibling's unwind is its own, the parent's is untouched.
fn parent_sibling_panics() -> int {
    let child: Brew<int> = brew napper_panics("sibling")
    let sibling: Brew<int> = brew quick()
    match sibling.join() {
        ok(v) => {}
        err(problem) => { io.println("  unexpected: {problem.kind}") }
    }
    let held: Res = new Res("parent-held-2")
    defer io.println("  parent older defer 2")
    defer report(child.join())
    let empty: List<int> = []
    return empty[2]
}

fn shield_finishes() -> string {
    let top: Brew<int> = brew parent_child_finishes()
    match top.join() {
        ok(v) => { return "child finishes during the parked cleanup: ok {v}" }
        err(problem) => { return "child finishes during the parked cleanup: {problem.kind}" }
    }
}

fn shield_sibling() -> string {
    let top: Brew<int> = brew parent_sibling_panics()
    match top.join() {
        ok(v) => { return "sibling panics during the parked cleanup: ok {v}" }
        err(problem) => { return "sibling panics during the parked cleanup: {problem.kind}" }
    }
}

fn main() {
    io.println(shield_finishes())
    io.println(shield_sibling())
}
