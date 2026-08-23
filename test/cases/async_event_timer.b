import std.async as aio
import std.io
import std.thread
import std.time

async fn event_value(event: aio.Event) -> int {
    await event.wait()
    return 2
}

async fn timer_value(delay_ms: int) -> int {
    await aio.sleep_millis(delay_ms)
    return 1
}

async fn wait_value(event: aio.Event) -> int {
    await event.wait()
    return 1
}

async fn main() {
    let sticky: aio.Event = new aio.Event()
    io.println("fresh {sticky.is_set()}")
    sticky.set()
    sticky.set()
    await sticky.wait()
    await sticky.wait()
    io.println("sticky {sticky.is_set()}")

    let signal: aio.Event = new aio.Event()
    let alias: aio.Event = signal
    let worker: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_nanos(50000000)
        alias.set()
        alias.set()
        return 7
    })
    let group: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    group.start(event_value(signal))
    group.start(timer_value(10))
    let first: int = (await group.next()).or(0)
    let second: int = (await group.next()).or(0)
    io.println("first {first}")
    io.println("second {second}")
    io.println("worker {worker.join()}")

    let before: int = time.monotonic_nanos()
    await aio.sleep_millis(20)
    let after_millis: int = time.monotonic_nanos()
    io.println(if after_millis - before >= 20000000 {
        "millis on time"
    } else {
        "millis early"
    })

    let deadline: int = time.monotonic_nanos() + 20000000
    await aio.sleep_until(deadline)
    io.println(if time.monotonic_nanos() >= deadline {
        "until on time"
    } else {
        "until early"
    })

    let cancelled: aio.Event = new aio.Event()
    let pending: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    pending.start(wait_value(cancelled))
    let empty: Option<int> = pending.try_next()
    pending.cancel_all()
    cancelled.set()
    io.println("cancelled")

    let temporary: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    temporary.start(wait_value(new aio.Event()))
    let still_empty: Option<int> = temporary.try_next()
    temporary.cancel_all()
    io.println("temporary")
}
