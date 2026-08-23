package async_rt

import std.thread

pub fn worker_run_task<T>(task: Task<T>) -> T {
    for {
        driver_cycle_begin()
        let status: int = task.poll_once()
        if status == 1 {
            let value: T = task.finish()
            driver_shutdown()
            return move value
        }
        if status == 0 { driver_wait() }
    }
}

pub fn worker_run_unit_task(task: Task<unit>) {
    for {
        driver_cycle_begin()
        let status: int = task.poll_once()
        if status == 1 {
            let taker: fn() -> unit = task.take_fn
            taker()
            driver_shutdown()
            return
        }
        if status == 0 { driver_wait() }
    }
}

pub fn spawn_async_adapter<T implements Send>(
    body: send async fn() -> T) -> Thread<T> {
    return spawn_async_adapter(body)
}

pub fn spawn_async_unit_adapter(
    body: send async fn() -> unit) -> Thread<unit> {
    return spawn_async_unit_adapter(body)
}
