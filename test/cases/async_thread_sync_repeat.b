import std.io
import std.thread

fn main() {
    let worker: Thread<int> =
        thread.spawn(fn() -> int { return 4 })
    io.println(worker.join())
    worker.join()
}
