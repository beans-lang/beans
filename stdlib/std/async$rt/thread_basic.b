package async_rt

import std.thread

pub fn worker_run_task<T>(task: Task<T>) -> T {
    for {
        driver_cycle_begin()
        let status: int = task.poll_once()
        if status == 1 { return task.finish() }
        if status == 0 { driver_wait_basic() }
    }
}

pub fn worker_run_unit_task(task: Task<unit>) {
    for {
        driver_cycle_begin()
        let status: int = task.poll_once()
        if status == 1 {
            let taker: fn() -> unit = task.take_fn
            taker()
            return
        }
        if status == 0 { driver_wait_basic() }
    }
}

// The expander replaces this checked placeholder with the real adapter. Its
// source signature is the public effect type; the generated worker closure
// sees the hidden Task<T> ABI only after async expansion.
pub fn spawn_async_adapter<T implements Send>(
    body: send async fn() -> T) -> Thread<T> {
    return spawn_async_adapter(body)
}

pub fn spawn_async_unit_adapter(
    body: send async fn() -> unit) -> Thread<unit> {
    return spawn_async_unit_adapter(body)
}
