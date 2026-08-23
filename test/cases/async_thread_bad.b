import std.async as aio
import std.thread

struct Holder {
    pub worker: Thread<int>
}

async fn borrowed(worker: Thread<int>) -> int {
    return (await worker.join_async()).or(0)
}

async fn field(holder: Holder) -> int {
    return (await holder.worker.join_async()).or(0)
}

async fn stored() {
    let worker: Thread<int> = thread.spawn_async(
        send async fn() -> int { return 1 })
    async let result: Result<int> = worker.join_async()
    let value: Result<int> = await result
}

async fn grouped() {
    let worker: Thread<int> = thread.spawn_async(
        send async fn() -> int { return 1 })
    let group: aio.TaskGroup<Result<int>> =
        new aio.TaskGroup<Result<int>>()
    group.start(worker.join_async())
}

async fn bare() {
    let worker: Thread<int> = thread.spawn_async(
        send async fn() -> int { return 1 })
    worker.join_async()
}

fn old_detach() {
    let worker: Thread<int> = thread.spawn(
        fn() -> int { return 1 })
    worker.detach()
}
