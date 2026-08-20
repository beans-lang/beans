import std.thread

class FakeHandle implements Send {}

fn main() {
    let handle: FakeHandle = new FakeHandle()
    let worker: Thread<int> = thread.spawn(fn() -> int {
        let used: FakeHandle = handle
        return 1
    })
    worker.join()
}
