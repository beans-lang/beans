// Cancellation cleans each frame and cascades through the existing scope joins.
// The ready gate establishes the park without a timing assumption.
import std.io
import std.time
import std.thread

class Held {
    pub label: string
    fn init(label: string) { self.label = label }
    fn deinit() { io.println("drop {self.label}") }
}

fn child(stop: Gate) -> int {
    let held: Held = new Held("child")
    defer io.println("child defer")
    stop.wait()
    return 8
}

fn join_child(stop: Gate) {
    let h: Brew<int> = brew child(stop)
    h.join()
}

fn next_child(stop: Gate) {
    let group: TaskGroup<int> = new TaskGroup()
    group.brew(child(stop))
    group.next()
}

fn wait_all_children(stop: Gate) {
    let group: TaskGroup<int> = new TaskGroup()
    group.brew(child(stop))
    group.wait_all()
}

fn park(mode: int, stop: Gate, ch: Channel<int>, ready: Gate) -> int {
    let held: Held = new Held("inner-{mode}")
    defer io.println("inner older {mode}")
    defer io.println("inner newer {mode}")
    ready.open()
    if mode == 0 { stop.wait() }
    if mode == 1 { ch.receive() }
    if mode == 2 { ch.send(2) }
    if mode == 3 { time.sleep_millis(5000) }
    if mode == 4 { join_child(stop) }
    if mode == 5 { next_child(stop) }
    if mode == 6 { wait_all_children(stop) }
    io.println("unexpected park return {mode}")
    return 9
}

fn contains_park(mode: int, stop: Gate, ch: Channel<int>, ready: Gate) -> int {
    let held: Held = new Held("middle-{mode}")
    defer io.println("middle defer {mode}")
    match contained park(mode, stop, ch, ready) {
        ok(v) => { return v }
        err(p) => { io.println("unexpected nested catch {p.kind}"); return -1 }
    }
}

fn worker(mode: int, stop: Gate, ch: Channel<int>, ready: Gate) -> int {
    let held: Held = new Held("outer-{mode}")
    defer io.println("outer defer {mode}")
    // Both layers of containment must pass cancellation to the fiber entry.
    match contained contains_park(mode, stop, ch, ready) {
        ok(v) => { io.println("unexpected contained ok {v}") }
        err(p) => { io.println("unexpected contained catch {p.kind}") }
    }
    return 4
}

fn run_case(mode: int) {
    let stop: Gate = new Gate()
    let ready: Gate = new Gate()
    let ch: Channel<int> = new Channel(1)
    if mode == 2 { ch.send(1) }
    let h: Brew<int> = brew worker(mode, stop, ch, ready)
    ready.wait()
    h.cancel()
    match h.join() {
        ok(v) => { io.println("unexpected join {v}") }
        err(p) => { io.println("joined {mode}: {p.kind}") }
    }
    // Cancelled waiters were unregistered; these operations remain usable.
    stop.open()
    ch.close()
}

fn thread_job(stop: Gate) -> int { stop.wait(); return 42 }

fn thread_waiter(t: Thread<int>, ready: Gate) -> int {
    let held: Held = new Held("thread-waiter")
    defer io.println("thread waiter defer")
    ready.open()
    return t.join()
}

fn thread_join_cancel() {
    let stop: Gate = new Gate()
    let ready: Gate = new Gate()
    let t: Thread<int> = thread.spawn(fn() -> int {
        return thread_job(stop)
    })
    let h: Brew<int> = brew thread_waiter(t, ready)
    ready.wait()
    h.cancel()
    match h.join() {
        ok(v) => { io.println("unexpected thread waiter {v}") }
        err(p) => { io.println("thread waiter: {p.kind}") }
    }
    // Cancelling one waiter did not consume or mark the thread joined.
    stop.open()
    io.println("thread result {t.join()}")
}

fn concurrent_thread_joins() {
    let stop: Gate = new Gate()
    let first_ready: Gate = new Gate()
    let second_ready: Gate = new Gate()
    let t: Thread<int> = thread.spawn(fn() -> int { return thread_job(stop) })
    let first: Brew<int> = brew thread_waiter(t, first_ready)
    first_ready.wait()
    let second: Brew<int> = brew thread_waiter(t, second_ready)
    second_ready.wait()
    // One join owns the thread's waiter slot. A second join must fail before
    // touching it, while a cancelled first join releases that reservation.
    match second.join() {
        ok(value) => { io.println("unexpected second join {value}") }
        err(problem) => { io.println("second thread join: {problem.kind}") }
    }
    let detacher: Brew<int> = brew detach_reserved_thread(t)
    match detacher.join() {
        ok(value) => { io.println("unexpected reserved detach {value}") }
        err(problem) => { io.println("reserved thread detach: {problem.kind}") }
    }
    stop.open()
    match first.join() {
        ok(value) => { io.println("first thread result {value}") }
        err(problem) => { io.println("unexpected first join {problem.kind}") }
    }
}

fn detach_reserved_thread(t: Thread<int>) -> int { t.detach(); return -1 }

struct WideThreadValue { answer: int; label: string }

fn wide_thread_waiter(t: Thread<WideThreadValue>, ready: Gate) -> WideThreadValue {
    defer io.println("wide waiter defer")
    ready.open()
    return t.join()
}

fn wide_thread_cancel() {
    let stop: Gate = new Gate()
    let ready: Gate = new Gate()
    let t: Thread<WideThreadValue> = thread.spawn(fn() -> WideThreadValue {
        stop.wait()
        return WideThreadValue { answer: 42, label: "wide" }
    })
    let h: Brew<WideThreadValue> = brew wide_thread_waiter(t, ready)
    ready.wait()
    h.cancel()
    match h.join() {
        ok(value) => { io.println("unexpected wide {value.answer}") }
        err(problem) => { io.println("wide waiter: {problem.kind}") }
    }
    stop.open()
    let value: WideThreadValue = t.join()
    io.println("{value.label} thread result {value.answer}")
}

fn older_child(ready: Gate, stop: Gate, release: Gate) -> int {
    let held: Held = new Held("older-child")
    defer release.open()
    ready.open()
    stop.wait()
    return 1
}

fn newer_cleanup(release: Gate) {
    io.println("newer cleanup waits")
    release.wait()
    io.println("newer cleanup finished")
}

fn newer_child(ready: Gate, stop: Gate, release: Gate) -> int {
    let held: Held = new Held("newer-child")
    defer newer_cleanup(release)
    ready.open()
    stop.wait()
    return 2
}

fn cleanup_pause(ready: Gate, stop: Gate) { ready.open(); stop.wait() }

fn conditional_cleanup_pause(ready: Gate, stop: Gate, mode: int) {
    if mode == 1 { cleanup_pause(ready, stop) }
}

fn implicit_parent(ready: Gate, stop: Gate, release: Gate, mode: int) -> Held {
    let held: Held = new Held("implicit-parent")
    defer io.println("implicit parent defer")
    let older_ready: Gate = new Gate()
    let a: Brew<int> = brew older_child(older_ready, stop, release)
    let b: Brew<int> = brew newer_child(ready, stop, release)
    defer conditional_cleanup_pause(ready, stop, mode)
    // This return's owned value must be dropped if its implicit join cancels.
    return new Held("discarded-return")
}

fn implicit_group_parent(ready: Gate, stop: Gate, release: Gate) -> Held {
    let held: Held = new Held("implicit-parent")
    defer io.println("implicit parent defer")
    let older_ready: Gate = new Gate()
    let group: TaskGroup<int> = new TaskGroup()
    group.brew(older_child(older_ready, stop, release))
    group.brew(newer_child(ready, stop, release))
    return new Held("discarded-return")
}

fn implicit_join_cancel(mode: int) {
    io.println("implicit cancellation {mode}")
    let ready: Gate = new Gate()
    let stop: Gate = new Gate()
    let release: Gate = new Gate()
    let parent: Brew<Held> = brew implicit_parent(ready, stop, release, mode)
    ready.wait()
    parent.cancel()
    parent.cancel()
    match parent.join() {
        ok(v) => { io.println("unexpected implicit result") }
        err(p) => { io.println("implicit parent: {p.kind}") }
    }
    stop.open()
}

fn implicit_group_cancel() {
    io.println("implicit group cancellation")
    let ready: Gate = new Gate()
    let stop: Gate = new Gate()
    let release: Gate = new Gate()
    let parent: Brew<Held> = brew implicit_group_parent(ready, stop, release)
    ready.wait()
    parent.cancel()
    match parent.join() {
        ok(v) => { io.println("unexpected implicit group result") }
        err(p) => { io.println("implicit group parent: {p.kind}") }
    }
    stop.open()
}

fn race_wait(ready: Gate, stop: Gate, ch: Channel<int>, mode: int) -> int {
    let held: Held = new Held("race-{mode}")
    defer io.println("race defer {mode}")
    ready.open()
    if mode == 0 { stop.wait(); return 7 }
    if mode == 1 {
        match ch.receive() { some(v) => { return v } none => { return -1 } }
    }
    ch.send(8)
    return 8
}

fn signal_wins(mode: int) {
    let ready: Gate = new Gate()
    let stop: Gate = new Gate()
    let ch: Channel<int> = new Channel(1)
    if mode == 2 { ch.send(1) }
    let h: Brew<int> = brew race_wait(ready, stop, ch, mode)
    ready.wait()
    if mode == 0 { stop.open() }
    if mode == 1 { ch.send(7) }
    if mode == 2 { ch.receive() }
    h.cancel()
    match h.join() {
        ok(v) => { io.println("signal won {mode}: {v}") }
        err(p) => { io.println("unexpected signal lost {p.kind}") }
    }
    if mode == 2 {
        match ch.receive() { some(v) => { io.println("committed send {v}") } none => {} }
    }
}

fn main() {
    for mode: int in 0..7 { run_case(mode) }
    thread_join_cancel()
    concurrent_thread_joins()
    wide_thread_cancel()
    implicit_join_cancel(0)
    implicit_join_cancel(1)
    implicit_group_cancel()
    for mode: int in 0..3 { signal_wins(mode) }
    io.println("done")
}
