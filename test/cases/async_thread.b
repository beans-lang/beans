import std.async as aio
import std.io
import std.thread

struct Wide {
    pub text: string
    pub number: int
}

unique class DropProbe implements Send {
    pub dropped: aio.Event

    pub fn init(dropped: aio.Event) { self.dropped = dropped }
    fn deinit() { self.dropped.set() }
}

unique class CaptureDrop implements Send {
    pub dropped: aio.Event

    pub fn init(dropped: aio.Event) { self.dropped = dropped }
    pub fn value() -> int { return 6 }
    fn deinit() { self.dropped.set() }
}

async fn delayed(value: int) -> int {
    await aio.sleep_millis(30)
    return value
}

async fn cancel_join(
    move worker: Thread<int>, started: aio.Event) -> int {
    started.set()
    return (await worker.join_async()).or(-1)
}

fn spawn_sync_capture(dropped: aio.Event) -> Thread<int> {
    let capture: CaptureDrop = new CaptureDrop(dropped)
    return thread.spawn(fn() move(capture) -> int {
        return capture.value()
    })
}

fn spawn_async_capture(dropped: aio.Event) -> Thread<int> {
    let capture: CaptureDrop = new CaptureDrop(dropped)
    return thread.spawn_async(
        send async fn() move(capture) -> int {
            await aio.yield_now()
            return capture.value()
        })
}

async fn main() {
    let completed: Thread<int> =
        thread.spawn_async(send async fn() -> int { return 3 })
    await aio.sleep_millis(10)
    let completed_value: int =
        (await completed.join_async()).or(0)
    io.println("completed {completed_value}")

    let survived: aio.Event = new aio.Event()
    let worker: Thread<int> = thread.spawn_async(
        send async fn() -> int {
            let value: int = await delayed(7)
            survived.set()
            return value
        })
    let started: aio.Event = new aio.Event()
    let cancellation: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    cancellation.start(cancel_join(move worker, started))
    let pending: Option<int> = cancellation.try_next()
    io.println("cancel {started.is_set()} {pending.is_none()}")
    cancellation.cancel_all()
    await survived.wait()
    io.println("worker survived {survived.is_set()}")

    let dropped: aio.Event = new aio.Event()
    let abandoned: Thread<DropProbe> = thread.spawn_async(
        send async fn() -> DropProbe {
            await aio.yield_now()
            return new DropProbe(dropped)
        })
    let abandoned_started: aio.Event = new aio.Event()
    let abandoning: aio.TaskGroup<int> = new aio.TaskGroup<int>()
    abandoning.start(cancel_abandoned(
        move abandoned, abandoned_started))
    let abandoned_pending: Option<int> = abandoning.try_next()
    abandoning.cancel_all()
    await dropped.wait()
    io.println("abandoned dropped {dropped.is_set()}")

    let retry: Thread<int> = thread.spawn_async(
        send async fn() -> int { return await delayed(7) })
    let retry_value: int = (await retry.join_async()).or(0)
    io.println("retry {retry_value}")
    match await retry.join_async() {
        ok(value) => { io.println("repeat bad {value}") }
        err(problem) => { io.println("repeat {problem.kind}") }
    }

    let captured: int = 4
    let closure_worker: Thread<int> = thread.spawn_async(
        send async fn() -> int {
            await aio.yield_now()
            return captured + 1
        })
    let captured_value: int =
        (await closure_worker.join_async()).or(0)
    io.println("capture {captured_value}")

    let sync_capture_dropped: aio.Event = new aio.Event()
    let sync_capture_worker: Thread<int> =
        spawn_sync_capture(sync_capture_dropped)
    let sync_capture_value: int = sync_capture_worker.join()
    io.println("sync capture {sync_capture_value} {sync_capture_dropped.is_set()}")

    let async_capture_dropped: aio.Event = new aio.Event()
    let async_capture_worker: Thread<int> =
        spawn_async_capture(async_capture_dropped)
    let async_capture_value: int =
        (await async_capture_worker.join_async()).or(0)
    io.println("async capture {async_capture_value} {async_capture_dropped.is_set()}")

    let unit_worker: Thread<unit> = thread.spawn_async(
        send async fn() -> unit { await aio.yield_now() })
    io.println(if (await unit_worker.join_async()).is_ok() {
        "unit ok"
    } else {
        "unit err"
    })

    let ref_worker: Thread<string> = thread.spawn_async(
        send async fn() -> string { return "reference" })
    io.println((await ref_worker.join_async()).or("bad"))

    let wide_worker: Thread<Wide> = thread.spawn_async(
        send async fn() -> Wide {
            return Wide { text: "wide", number: 8 }
        })
    match await wide_worker.join_async() {
        ok(value) => { io.println("{value.text} {value.number}") }
        err(_) => { io.println("wide bad") }
    }

    let result_worker: Thread<Result<int>> = thread.spawn_async(
        send async fn() -> Result<int> { return ok(9) })
    match await result_worker.join_async() {
        ok(inner) => { io.println("result {inner.or(0)}") }
        err(_) => { io.println("result bad") }
    }
}

async fn cancel_abandoned(
    move worker: Thread<DropProbe>, started: aio.Event) -> int {
    started.set()
    return if (await worker.join_async()).is_ok() { 1 } else { 0 }
}
