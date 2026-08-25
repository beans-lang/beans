import std.io

@runtime_hook(before: "trace_before", after_return: "trace_after")
@target(value: ["function", "method"])
@repeatable
annotation trace {
    label: string
    number: int = 1
}

fn trace_before(target: string, label: string, number: int) {
    io.println("before:{target}:{label}:{number}")
}

fn trace_after(target: string, label: string, number: int) {
    io.println("after:{target}:{label}:{number}")
}

@runtime_hook(before: "reentrant_before")
@target(value: ["function"])
annotation reentrant {}

fn reentrant_before(target: string) {
    io.println("guard:{target}")
    nested_from_handler()
}

@reentrant
fn nested_from_handler() {
    io.println("body:nested")
}

@reentrant
fn guarded() {
    io.println("body:guarded")
}

@runtime_start
fn start_first() {
    io.println("start:first")
}

@runtime_start
fn start_second() {
    io.println("start:second")
}

@runtime_stop
fn stop_first() {
    io.println("stop:first")
}

@runtime_stop
fn stop_second() {
    io.println("stop:second")
}

class Worker {
    @trace(label: "method", number: 3)
    fn run() {
        io.println("body:method")
    }
}

@trace(label: "outer")
@trace(label: "inner", number: 2)
fn work(leave_early: bool) {
    io.println("body:work")
    if leave_early { return }
    io.println("body:late")
}

fn main() {
    work(true)
    let worker: Worker = new Worker()
    worker.run()
    guarded()
}
