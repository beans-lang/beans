// A panic contained by brew/join unwinds the fiber's frames instead of
// abandoning them (issue #44, spec/CONCURRENCY.md): every frame between the
// failure and the fiber entry runs its defers newest-first and drops what it
// owns, exactly as a return would. The interpreter and the native backend
// host fibers on the same scheduler and run the same cleanup, so this is
// byte-identical between them — order included. Reverting either backend's
// half leaves cleanup unrun and this golden no longer matches.
import std.io

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

// A move-only local, to exercise the move-only drop on the unwind path.
unique class Token {
    pub id: int
    fn init(id: int) { self.id = id }
    fn deinit() { io.println("  drop token {self.id}") }
}

class Counter {
    pub n: int = 0
    pub fn up() { self.n += 1 }
    pub fn down() { self.n -= 1 }
}

// The innermost frame: two owned locals and three defers, then a panic. The
// defers must run newest-first (B, then A, then the counter defer), and the
// owned locals must drop newest-first after them.
fn deep(c: Counter) -> int {
    let first: Res = new Res("deep-first")
    let second: Res = new Res("deep-second")
    c.up()
    defer c.down()
    defer io.println("  deep defer A")
    defer io.println("  deep defer B")
    let empty: List<int> = []
    return empty[7]
}

// A middle frame with its own owned local and defer, so the unwind has to
// cross more than one function boundary to reach the fiber entry.
fn middle(c: Counter) -> int {
    let held: Res = new Res("middle-held")
    defer io.println("  middle defer")
    return deep(c)
}

// A move-only owned local must run its deinit on the way out too.
fn with_moveonly() -> int {
    let t: Token = new Token(7)
    defer io.println("  moveonly defer")
    let empty: List<int> = []
    return empty[0]
}

// A captured local lives in a heap cell shared with the closure; the cell,
// and the value it holds, must be released on the unwind (its Res deinit runs
// once). The closure is never called — only its capture matters here.
fn with_capture() -> int {
    let r: Res = new Res("captured-res")
    let f: fn() -> unit = fn() { io.println("  see {r.tag}") }
    defer io.println("  capture defer")
    let empty: List<int> = []
    return empty[0]
}

fn shielded(c: Counter, label: string) -> string {
    let child: Brew<int> = brew middle(c)
    match child.join() {
        ok(v) => { return "ok {v}" }
        err(problem) => { return "{label}: {problem.kind}" }
    }
}

fn shield_moveonly() -> string {
    let child: Brew<int> = brew with_moveonly()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "moveonly: {problem.kind}" }
    }
}

fn shield_capture() -> string {
    let child: Brew<int> = brew with_capture()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "capture: {problem.kind}" }
    }
}

// The espresso shielded-handle shape: a handler is called through `?`, and the
// handler panics. The operand's panic is already in flight when `?` is
// reached, so `?` must short-circuit rather than see the poisoned unit as a
// non-result and raise a second failure inside the unwind — which the
// interpreter would report as a double panic and abort. The handler still
// drops what it owns on the way out.
fn faulty() -> Result<int> {
    let held: Res = new Res("faulty-held")
    panic("faulty lost it")
    return ok(0)
}

fn pipeline() -> Result<int> {
    let produced: int = faulty()?
    return ok(produced)
}

fn shield_pipeline() -> string {
    let child: Brew<Result<int>> = brew pipeline()
    match child.join() {
        ok(r) => { return "ok" }
        err(problem) => { return "pipeline: {problem.kind}" }
    }
}

// A defer that panics on the normal return path. The panic is contained, so
// the unwind takes over the rest of the frame's cleanup: the defer that
// panicked does not run a second time, the older defer still runs, and the
// local drops. The native backend once re-ran the panicking defer from its
// cleanup pad and died of a double panic.
fn boom_unit() { let empty: List<int> = []; let unused: int = empty[2] }

fn defer_panics() -> int {
    let local: Res = new Res("dp-local")
    defer io.println("  dp older defer")
    defer boom_unit()
    return 0
}

fn shield_defer_panic() -> string {
    let child: Brew<int> = brew defer_panics()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "defer-panic: {problem.kind}" }
    }
}

// A deinit that panics while a frame drops its locals on the normal path.
// The panic is contained; the object whose deinit panicked is abandoned
// mid-destruction and is not released a second time, and the locals that
// had not dropped yet still drop.
class Bomb {
    fn deinit() {
        io.println("  deinit bomb panics")
        let empty: List<int> = []
        let unused: int = empty[0]
    }
}

fn deinit_panics() -> int {
    let first: Res = new Res("first")
    let bomb: Bomb = new Bomb()
    let last: Res = new Res("last")
    return 1
}

fn shield_deinit_panic() -> string {
    let child: Brew<int> = brew deinit_panics()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "deinit-panic: {problem.kind}" }
    }
}

fn main() {
    let c: Counter = new Counter()
    io.println(shielded(c, "first"))
    var i: int = 0
    for i < 4 {
        io.println(shielded(c, "loop"))
        i += 1
    }
    io.println("counter after 5 contained panics: {c.n}")
    io.println(shield_moveonly())
    io.println(shield_capture())
    io.println(shield_pipeline())
    io.println(shield_defer_panic())
    io.println(shield_deinit_panic())
}
