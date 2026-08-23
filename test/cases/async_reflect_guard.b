package main

import std.io
import std.reflect
import std.reflection as rt

unique class Task<T> {
    poll_fn: fn() -> int
    take_fn: fn() -> T
    cancel_fn: fn()
    finished: bool = false

    fn init(poll_fn: fn() -> int, take_fn: fn() -> T,
            cancel_fn: fn()) {
        self.poll_fn = poll_fn
        self.take_fn = take_fn
        self.cancel_fn = cancel_fn
    }

    fn poll_once() -> int {
        if self.finished { return 1 }
        let poll: fn() -> int = self.poll_fn
        let status: int = poll()
        if status == 1 { self.finished = true }
        return status
    }

    fn cancel_now() {
        if self.finished { return }
        let cancel: fn() = self.cancel_fn
        cancel()
        self.finished = true
    }

    fn deinit() {
        if !self.finished { self.cancel_now() }
    }
}

class GuardCounts {
    static drops: int = 0
}

unique class GuardProbe {
    fn deinit() { GuardCounts.drops += 1 }
}

pub async fn ready_unique() -> GuardProbe {
    return new GuardProbe()
}

fn drop_ready_without_take() {
    let function: int = rt.function_handle("main.ready_unique")
    let handle: int = rt.function_call_async_handle(function, 0, 0)
    if handle == 0 { panic("reflected async call did not start") }
    // reflect_call_task is copied from the real compiler-private bridge by
    // the test driver. Dropping after READY without finish is the ownership
    // edge this regression protects.
    let task: Task<int> = reflect_call_task(handle)
    if task.poll_once() != 1 { panic("guard task was not ready") }
}

fn main() {
    drop_ready_without_take()
    io.println(GuardCounts.drops)
}
