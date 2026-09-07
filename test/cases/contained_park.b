// A catch frame belongs to ONE fiber (issue #145, spec/CONCURRENCY.md). Both
// backends keep the count of standing frames on the fiber record, not on the
// thread, and this is the program that tells the two apart: fibers of a worker
// share thread storage but not stacks, so a frame on one fiber's stack is not
// one another fiber's failure can reach.
//
// Each case parks the fiber that holds the frame, which lets a sibling run,
// panic, be cancelled or contain a failure of its own while that frame stands.
// With a per-thread count every one of them reads the wrong answer.
import std.io
import std.time

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

// Parks long enough for a sibling to run to completion, then returns.
fn naps(label: string, millis: int) -> int {
    io.println("  {label} parks")
    time.sleep_millis(millis)
    io.println("  {label} wakes")
    return 1
}

fn naps_then_panics(label: string, millis: int) -> int {
    io.println("  {label} parks")
    time.sleep_millis(millis)
    let r: Res = new Res("{label}-held")
    panic("{label} refused")
}

// ---- 1. a sibling's uncontained panic is not this frame's ------------------
//
// The root fiber stands inside a contained call and parks there. A brewed
// sibling panics while it waits, with no catch frame of its own. That panic
// belongs to the sibling's join. If the count were per thread, the sibling
// would have read the root's standing frame, unwound looking for a pad that
// is not on its stack, and ended with the wrong status.

fn parks_then_returns(millis: int) -> string {
    io.println("  parent parks inside its catch frame")
    time.sleep_millis(millis)
    return "parent returned"
}

fn sibling_panics() {
    io.println("sibling panics while a frame stands:")
    let child: Brew<int> = brew naps_then_panics("sibling", 20)
    match contained parks_then_returns(60) {
        ok(v) => { io.println("  contained ok: {v}") }
        err(p) => { io.println("  contained caught {p.kind}") }
    }
    match child.join() {
        ok(v) => { io.println("  sibling ok {v}") }
        err(p) => { io.println("  sibling {p.kind}") }
    }
}

// ---- 2. two fibers, each with its own frame -------------------------------
//
// Both are inside a contained call at the same time and both fail. Each must
// catch its own failure and neither may see the other's.

fn fails_after(label: string, millis: int) -> int {
    time.sleep_millis(millis)
    panic("{label} refused")
}

fn contains_its_own(label: string, millis: int) -> string {
    match contained fails_after(label, millis) {
        ok(v) => { return "{label} unexpected ok {v}" }
        err(p) => { return "{label} caught {p.kind}" }
    }
}

fn overlapping_frames() {
    io.println("two overlapping catch frames:")
    let a: Brew<string> = brew contains_its_own("A", 40)
    let b: Brew<string> = brew contains_its_own("B", 10)
    match b.join() {
        ok(v) => { io.println("  {v}") }
        err(p) => { io.println("  B join err {p.kind}") }
    }
    match a.join() {
        ok(v) => { io.println("  {v}") }
        err(p) => { io.println("  A join err {p.kind}") }
    }
}

// ---- 3. a cancel is not contained ----------------------------------------
//
// A cancel is delivered at a park and does NOT unwind on either backend, so it
// never reaches a catch frame: the fiber ends and the join reports `cancelled`.
// The contained call inside it simply never returns.

fn sleeps_forever() -> int {
    io.println("  cancellable work starts")
    time.sleep_millis(4000)
    io.println("  cancellable work should not get here")
    return 2
}

fn contains_a_cancellable() -> int {
    match contained sleeps_forever() {
        ok(v) => {
            io.println("  should not catch a cancel")
            return v
        }
        err(p) => {
            io.println("  should not catch a cancel: {p.kind}")
            return -1
        }
    }
}

fn cancel_is_not_caught() {
    io.println("a cancel is not caught:")
    let c: Brew<int> = brew contains_a_cancellable()
    time.sleep_millis(60)
    c.cancel()
    match c.join() {
        ok(v) => { io.println("  join ok {v}") }
        err(p) => { io.println("  join {p.kind}") }
    }
}

// ---- 4. a fiber record reused after a cancel -----------------------------
//
// The cancelled fiber above left its catch frame standing on a record the
// scheduler pools. The next fiber at that address must start with none: it
// panics with no frame of its own, and its join has to say `panic`, not
// deliver a failure to a frame that died with someone else.

fn plain_panics() -> int {
    let r: Res = new Res("after-reuse")
    panic("after reuse")
}

fn reused_record() {
    io.println("record reused after a cancel:")
    let c: Brew<int> = brew plain_panics()
    match c.join() {
        ok(v) => { io.println("  join ok {v}") }
        err(p) => { io.println("  join {p.kind}: {p.msg}") }
    }
    match contained plain_panics() {
        ok(v) => { io.println("  contained unexpected ok {v}") }
        err(p) => { io.println("  contained caught {p.kind}") }
    }
}

fn main() {
    sibling_panics()
    overlapping_frames()
    cancel_is_not_caught()
    reused_record()
    io.println("done")
}
