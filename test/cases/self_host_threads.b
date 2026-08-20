import std.io
import std.thread

fn main() {
    let value: AtomicInt = new AtomicInt(1)
    let worker: Thread<int> =
        thread.spawn(fn() -> int {
            value.store(7)
            return value.load()
        })
    // Cross-thread mutation is explicit and synchronized. Later parent
    // declarations still must not resize the environment the worker reads.
    let later: int = 9
    io.println(
        "{worker.join()} {value.load()} {later}")
}
