// Gate (spec/CONCURRENCY.md, F3): a sticky broadcast flag. One open wakes
// every parked waiter at once — same-worker fibers and fibers parked while
// an OS thread fires the open — and the gate stays open for every later
// wait. The differential gate runs this on both engines and demands
// byte-identical output, scheduling order included.
import std.io
import std.thread as thread
import std.time as time

fn watcher(gate: Gate, id: int) -> int {
    gate.wait()
    io.println("watcher {id} through")
    return id
}

fn opener(gate: Gate) -> int {
    io.println("opening")
    gate.open()
    return 1
}

fn late_open(gate: Gate) -> int {
    time.sleep_millis(30)
    gate.open()
    return 7
}

fn main() {
    // same-worker: two watchers park, a third fiber opens the gate,
    // and the whole wait line wakes in FIFO order
    let gate: Gate = new Gate()
    io.println("open {gate.is_open()}")
    let first: Brew<int> = brew watcher(gate, 1)
    let second: Brew<int> = brew watcher(gate, 2)
    let open: Brew<int> = brew opener(gate)
    var total: int = 0
    match first.join() {
        ok(value) => { total = total + value }
        err(error) => { io.println("first failed") }
    }
    match second.join() {
        ok(value) => { total = total + value }
        err(error) => { io.println("second failed") }
    }
    match open.join() {
        ok(value) => { total = total + value }
        err(error) => { io.println("open failed") }
    }
    io.println("total {total} open {gate.is_open()}")

    // sticky: a wait after the open never parks
    gate.wait()
    io.println("sticky pass")

    // cross-thread: main parks on a shut gate and an OS thread fires the
    // open — the wake crosses back into the parked fiber's worker
    let late: Gate = new Gate()
    let t: Thread<int> =
        thread.spawn(fn() -> int { return late_open(late) })
    late.wait()
    io.println("woken across threads {late.is_open()}")
    io.println("thread said {t.join()}")
}
