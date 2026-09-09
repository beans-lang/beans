// The other half of the `unit` rule (issue #154): `unit` IS what a function
// that returns nothing answers with, so every shape that only *names* a
// result — a declared `-> unit`, a closure type, and the payload of a handle,
// which is the result type of the call the handle runs — has to keep working,
// on both backends, byte for byte.
//
// Every one of these builds and runs on 0.1.40. A refusal written on the
// spelling `unit` rather than on the slot it lands in would take all of them
// out, so this file is the guard on the refusal in unit_value_bad.b.
import std.io
import std.thread

fn work(step: int) {
    io.println("work {step}")
}

// a declared unit result, spelled out
fn announce(label: string) -> unit {
    io.println("announce {label}")
}

class Worker {
    pub tag: string = "w"
    pub fn run(step: int) {
        io.println("{self.tag} runs {step}")
    }
}

// T binds to `unit` through a function RESULT — the slot where it belongs.
// Nobody writes `unit` anywhere in the call.
fn produced<T>(make: fn() -> T) -> int {
    make()
    return 21
}

fn each_of(items: List<int>, apply: fn(int)) {
    for item: int in items {
        apply(item)
    }
}

// A kept handle nobody joins: the synthesized scope join waits for it.
fn kept_handle() {
    let first: Brew<unit> = brew work(1)
    let second: Brew<unit> = brew work(2)
    io.println("kept two")
}

// A handle that is cancelled rather than joined.
fn cancelled_handle() {
    let handle: Brew<unit> = brew work(3)
    handle.cancel()
    io.println("cancelled one")
}

// The statement form: no handle at all.
fn statement_form() {
    brew work(4)
    brew work(5)
    io.println("brewed two")
}

// A unit-returning method on a class receiver.
fn method_handle() {
    let worker: Worker = new Worker()
    let handle: Brew<unit> = brew worker.run(6)
    io.println("brewed a method")
}

// A whole fleet of unit children, drained by cancel_all rather than by next.
fn fleet() {
    let group: TaskGroup<unit> = new TaskGroup<unit>()
    group.brew(work(7))
    group.brew(work(8))
    group.brew(work(9))
    group.cancel_all()
    io.println("fleet cancelled")
}

// A thread whose closure answers nothing: Thread<unit>.join() answers unit,
// not Result<unit>, which is why this one is emittable and a brew join is not.
fn spawned() {
    let worker: Thread<unit> = thread.spawn(fn() {
        io.println("on a thread")
    })
    worker.join()
    io.println("thread joined")
}

fn main() {
    announce("start")
    kept_handle()
    cancelled_handle()
    statement_form()
    method_handle()
    fleet()
    spawned()
    io.println("produced {produced(fn() { })}")
    let printer: fn(int) = fn(step: int) {
        io.println("printer {step}")
    }
    printer(10)
    each_of([11, 12, 13], printer)
    let counter: Mutex<int> = new Mutex<int>(14)
    counter.with_lock(fn(value: int) {
        io.println("locked {value}")
    })
    io.println("done")
}
