import std.async as aio
import std.thread

class ExitCycle {
    next: Option<ExitCycle> = none
}

fn make_exit_cycles() {
    for unused: int in 0..1000 {
        var first: ExitCycle = new ExitCycle()
        var second: ExitCycle = new ExitCycle()
        first.next = some(second)
        second.next = some(first)
    }
}

async fn main() {
    let sync_worker: Thread<int> =
        thread.spawn(fn() -> int {
            make_exit_cycles()
            return 1
        })
    sync_worker.join()

    let async_worker: Thread<int> =
        thread.spawn_async(send async fn() -> int {
            await aio.yield_now()
            make_exit_cycles()
            return 2
        })
    await async_worker.join_async()
}
