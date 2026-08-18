import std.io
import std.thread

fn main() {
    var value: int = 1
    let worker: Thread<int> =
        thread.spawn(fn() -> int {
            value = 7
            return value
        })
    // A spawned capture is one stable cell. Rebinding it in the worker must
    // remain visible to the parent, while later parent declarations must not
    // resize the environment the worker reads.
    let later: int = 9
    io.println(
        "{worker.join()} {value} {later}")
}
